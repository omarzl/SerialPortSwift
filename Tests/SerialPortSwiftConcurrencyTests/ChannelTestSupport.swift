//
//  ChannelTestSupport.swift
//  SerialPortSwiftConcurrencyTests
//
//  What the suites of `SerialChannel` share: a rig (a replay stream, a channel over it and a recorder of
//  its events), a stream the test drives by hand, and the waits a test needs.
//

#if compiler(>=5.7) && canImport(_Concurrency)

    import Foundation
    import SerialPortSwift
    @testable import SerialPortSwiftConcurrency
    import SerialPortSwiftSimulation
    import XCTest

    // MARK: - Small helpers

    func ascii(_ string: String) -> Data {
        return Data(string.utf8)
    }

    func exchange(
        _ number: Int,
        _ frame: String,
        reply: ReplyShape = .exactly(1),
        timeout: TimeInterval? = nil
    ) -> SerialExchange {
        return SerialExchange(id: SerialExchangeID(number: number), frame: ascii(frame), reply: reply, timeout: timeout)
    }

    func id(_ number: Int) -> SerialExchangeID {
        return SerialExchangeID(number: number)
    }

    /// The matcher a filler-padding device needs: 0xFF is ignored, replies are ASCII and counted in
    /// characters.
    var paddedMatcher: TailScanMatcher {
        return TailScanMatcher(fillerBytes: [0xFF], requiresASCII: true, lengthUnit: .characters)
    }

    /// The error a piece of work ends with, or `nil` when it ends without one.
    @available(macOS 10.15, *)
    func errorOf<T>(_ work: () async throws -> T) async -> Error? {
        do {
            _ = try await work()
            return nil
        } catch {
            return error
        }
    }

    /// A flag a task can raise and a test can read.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false

        var isRaised: Bool {
            lock.lock()
            defer { lock.unlock() }
            return raised
        }

        func raise() {
            lock.lock()
            raised = true
            lock.unlock()
        }
    }

    /// A value a task can set and a test can read.
    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value

        init(_ value: Value) {
            stored = value
        }

        var value: Value {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }

        /// Changes the value in one step, so that tasks that change it at once lose none of the changes.
        func mutate(_ change: (inout Value) -> Void) {
            lock.lock()
            change(&stored)
            lock.unlock()
        }
    }

    // MARK: - What the channel keeps, for the tests

    /// How many requests and writes wait their turn on `channel`.
    @available(macOS 10.15, *)
    func queuedCount(of channel: SerialChannel) async -> Int {
        return await channel.queuedCount
    }

    /// How many streams of `channel.events()` are still being consumed.
    @available(macOS 10.15, *)
    func eventConsumerCount(of channel: SerialChannel) async -> Int {
        return await channel.eventConsumerCount
    }

    /// Waits until `channel` has `count` consumers of its events.
    @available(macOS 10.15, *)
    func waitForEventConsumers(_ count: Int, of channel: SerialChannel) async {
        await waitUntil { await eventConsumerCount(of: channel) == count }
    }

    /// How many calls of `channel.waitUntilIdle()` are still waiting.
    @available(macOS 10.15, *)
    func idleWaiterCount(of channel: SerialChannel) async -> Int {
        return await channel.idleWaiterCount
    }

    /// Fires the timer of the exchange that `token` names, as its task would when it runs out: a token that
    /// names no exchange on the wire is a timer that is late, and must change nothing. The first exchange a
    /// channel writes has token 1, the second 2, and so on.
    @available(macOS 10.15, *)
    func fireTimeout(_ token: Int, of channel: SerialChannel) async {
        await channel.timeoutFired(token)
    }

    /// Ends the pause that `token` names, as its task would when it runs out. The first pause a channel
    /// starts has token 1, the second 2, and so on.
    @available(macOS 10.15, *)
    func endPause(_ token: Int, of channel: SerialChannel) async {
        await channel.gapEnded(token)
    }

    // MARK: - Waiting

    /// Polls `condition` until it holds, failing the test after `timeout`.
    @available(macOS 10.15, *)
    @discardableResult
    func waitUntil(
        timeout: TimeInterval = 5,
        report: Bool = true,
        file: StaticString = #file,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !(await condition()) {
            if Date() >= deadline {
                if report {
                    XCTFail("Timed out waiting for a condition", file: file, line: line)
                }
                return false
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }

    /// Lets `seconds` pass, so anything that should not happen has its chance.
    @available(macOS 10.15, *)
    func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Whether `work` finishes within `seconds`. Work that does not is left running.
    @available(macOS 10.15, *)
    func completes(within seconds: TimeInterval = 2, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        let finished = Flag()
        Task {
            await work()
            finished.raise()
        }
        return await waitUntil(timeout: seconds, report: false) { finished.isRaised }
    }

    // MARK: - Events

    /// What happened on a channel, without the bytes and times, so a test can compare sequences.
    enum Tag: Equatable {
        case opened
        case closed(SerialCloseReason)
        case sent(Int?)
        case raw
        case answered(Int)
        case timedOut(Int)
        case unreadable(Int)
        case late
        case unsolicited
        case cancelled([Int])

        init(_ kind: SerialQueueEvent.Kind) {
            switch kind {
            case .opened:
                self = .opened
            case .closed(let reason):
                self = .closed(reason)
            case .sent(let id):
                self = .sent(id?.number)
            case .raw:
                self = .raw
            case .answered(let id, _):
                self = .answered(id.number)
            case .timedOut(let id):
                self = .timedOut(id.number)
            case .unreadableCandidate(let id):
                self = .unreadable(id.number)
            case .lateBytesDropped:
                self = .late
            case .unsolicitedBytesDropped:
                self = .unsolicited
            case .cancelled(let ids):
                self = .cancelled(ids.map { $0.number })
            }
        }
    }

    /// Consumes `channel.events()` in a task of its own and keeps what it sees.
    @available(macOS 10.15, *)
    final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [SerialQueueEvent] = []
        private var hook: (@Sendable (SerialQueueEvent) -> Void)?
        private var task: Task<Void, Never>?

        /// Starts recording from now on. The stream is made before this returns, so nothing that happens
        /// afterwards is missed.
        static func attach(to channel: SerialChannel, onEvent: (@Sendable (SerialQueueEvent) -> Void)? = nil) async -> EventRecorder {
            let recorder = EventRecorder()
            recorder.hook = onEvent
            let events = await channel.events()
            recorder.task = Task {
                for await event in events {
                    recorder.add(event)
                }
            }
            return recorder
        }

        private func add(_ event: SerialQueueEvent) {
            lock.lock()
            recorded.append(event)
            let callback = hook
            lock.unlock()
            callback?(event)
        }

        func stop() {
            task?.cancel()
        }

        /// Waits until the recording task has finished: the events stream ended.
        func waitUntilEnded() async {
            await task?.value
        }

        var events: [SerialQueueEvent] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        var tags: [Tag] {
            return events.map { Tag($0.kind) }
        }

        var tagsWithoutRaw: [Tag] {
            return tags.filter { $0 != .raw }
        }

        func has(_ tag: Tag) -> Bool {
            return tags.contains(tag)
        }

        func firstEvent(_ tag: Tag) -> SerialQueueEvent? {
            return events.first { Tag($0.kind) == tag }
        }

        func bytes(of tag: Tag) -> Data? {
            return firstEvent(tag)?.bytes
        }

        /// The time between the first events tagged `start` and `end`, by the wall clock.
        func elapsed(from start: Tag, to end: Tag, file: StaticString = #file, line: UInt = #line) -> TimeInterval {
            guard let first = firstEvent(start), let second = firstEvent(end) else {
                XCTFail("Missing \(start) or \(end) in \(tags)", file: file, line: line)
                return 0
            }
            return second.date.timeIntervalSince(first.date)
        }

        /// Waits until the events, without the raw ones, are `expected`, then for a moment more to see
        /// that nothing else follows, and asserts they are.
        func expectTagsWithoutRaw(_ expected: [Tag], file: StaticString = #file, line: UInt = #line) async {
            await expect(expected, includingRaw: false, file: file, line: line)
        }

        /// The same, raw events included.
        func expectTags(_ expected: [Tag], file: StaticString = #file, line: UInt = #line) async {
            await expect(expected, includingRaw: true, file: file, line: line)
        }

        private func expect(_ expected: [Tag], includingRaw: Bool, file: StaticString, line: UInt) async {
            let current: () -> [Tag] = { includingRaw ? self.tags : self.tagsWithoutRaw }
            await waitUntil(report: false) { current() == expected }
            await settle(0.05)
            XCTAssertEqual(current(), expected, file: file, line: line)
        }
    }

    // MARK: - Rig

    /// A replay stream, a channel over it and a recorder of the channel's events.
    @available(macOS 10.15, *)
    final class Rig: @unchecked Sendable {
        let stream: ReplayByteStream
        let channel: SerialChannel
        let recorder: EventRecorder

        init(
            script: [ReplayStep],
            openFailure: SerialStreamError?,
            matcher: ReplyMatcher,
            defaultTimeout: TimeInterval,
            gap: TimeInterval,
            maximumReplyLength: Int
        ) async {
            stream = ReplayByteStream(script: script, openFailure: openFailure)
            channel = SerialChannel(
                stream: stream,
                matcher: matcher,
                configuration: SerialChannel.Configuration(
                    defaultTimeout: defaultTimeout,
                    maximumReplyLength: maximumReplyLength,
                    postTimeoutGap: gap
                )
            )
            self.recorder = await EventRecorder.attach(to: channel)
        }

        var writtenFrames: [Data] {
            return stream.writes.map { $0.bytes }
        }

        func shutDown() async {
            await channel.close()
            recorder.stop()
        }
    }

    /// Runs `body` with a rig whose channel is open (unless `open` is `false`), and closes the channel
    /// afterwards.
    @available(macOS 10.15, *)
    func withRig(
        script: [ReplayStep] = [],
        openFailure: SerialStreamError? = nil,
        matcher: ReplyMatcher = TailScanMatcher(),
        defaultTimeout: TimeInterval = 5,
        gap: TimeInterval = 0,
        maximumReplyLength: Int = 64,
        open: Bool = true,
        _ body: (Rig) async throws -> Void
    ) async throws {
        let rig = await Rig(
            script: script,
            openFailure: openFailure,
            matcher: matcher,
            defaultTimeout: defaultTimeout,
            gap: gap,
            maximumReplyLength: maximumReplyLength
        )
        do {
            if open {
                try await rig.channel.open()
            }
            try await body(rig)
        } catch {
            await rig.shutDown()
            throw error
        }
        await rig.shutDown()
    }

    // MARK: - Streams and matchers

    /// A stream the test drives by hand, to hold the channel in the states a synchronous stream skips.
    /// By default `open()` and `close()` report nothing and the test calls `completeOpen` and
    /// `completeClose` itself; `closeReport` makes `close()` report before it returns, as the streams
    /// in the package do for a stream that is open. `onWrite` runs with every frame written, on the thread
    /// that writes it: the channel's actor, when the channel does.
    final class ManualByteStream: SerialByteStream, @unchecked Sendable {
        let name = "manual"
        weak var delegate: SerialByteStreamDelegate?

        private let lock = NSLock()
        private var opens = 0
        private var closes = 0
        private var written: [Data] = []
        private var report: SerialCloseReason?
        private var writeHook: (@Sendable (Data) -> Void)?

        var onWrite: (@Sendable (Data) -> Void)? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return writeHook
            }
            set {
                lock.lock()
                writeHook = newValue
                lock.unlock()
            }
        }

        var closeReport: SerialCloseReason? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return report
            }
            set {
                lock.lock()
                report = newValue
                lock.unlock()
            }
        }

        var openCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return opens
        }

        var closeCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return closes
        }

        var writes: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return written
        }

        func open() {
            lock.lock()
            opens += 1
            lock.unlock()
        }

        func close() {
            lock.lock()
            closes += 1
            let reason = report
            lock.unlock()
            if let reason = reason {
                delegate?.streamDidClose(self, reason: reason)
            }
        }

        func write(_ bytes: Data) {
            lock.lock()
            written.append(bytes)
            let hook = writeHook
            lock.unlock()
            hook?(bytes)
        }

        func completeOpen() {
            delegate?.streamDidOpen(self)
        }

        func deliver(_ bytes: Data) {
            delegate?.stream(self, didReceive: bytes)
        }

        func completeClose(_ reason: SerialCloseReason) {
            delegate?.streamDidClose(self, reason: reason)
        }
    }

    /// Records the buffers a matcher is asked to scan, and never finds a reply.
    final class ScanLog: @unchecked Sendable {
        private let lock = NSLock()
        private var scanned: [Data] = []
        private var starts: [Int] = []

        func add(_ buffer: Data) {
            lock.lock()
            scanned.append(buffer)
            starts.append(buffer.startIndex)
            lock.unlock()
        }

        var buffers: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return scanned
        }

        var startIndexes: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return starts
        }
    }

    /// A matcher that runs `hook` at every scan, then scans as the default `TailScanMatcher` does. The channel
    /// scans on its actor, so the hook runs where the channel's own work does: nothing else on the channel
    /// moves until it returns, which lets a test do something at a moment that is otherwise a race.
    struct HookedMatcher: ReplyMatcher {
        let hook: @Sendable () -> Void
        private let inner = TailScanMatcher()

        init(_ hook: @escaping @Sendable () -> Void) {
            self.hook = hook
        }

        func verdict(on candidate: Data, expecting shape: ReplyShape) -> ReplyVerdict {
            return inner.verdict(on: candidate, expecting: shape)
        }

        func scan(_ buffer: Data, expecting shape: ReplyShape) -> ReplyScan {
            hook()
            return inner.scan(buffer, expecting: shape)
        }
    }

    struct LoggingMatcher: ReplyMatcher {
        let log: ScanLog

        func verdict(on candidate: Data, expecting shape: ReplyShape) -> ReplyVerdict {
            return .rejected
        }

        func scan(_ buffer: Data, expecting shape: ReplyShape) -> ReplyScan {
            log.add(buffer)
            return ReplyScan(packet: nil, unreadable: nil)
        }
    }

    /// A device that answers each frame with what `answer` makes of it.
    final class ScriptedDevice: SerialDeviceSimulator, @unchecked Sendable {
        private let answer: @Sendable (Data) -> Data?

        init(_ answer: @escaping @Sendable (Data) -> Data?) {
            self.answer = answer
        }

        func reply(to frame: Data) -> Data? {
            return answer(frame)
        }
    }

    /// A manual stream, a channel over it and a recorder of the channel's events.
    @available(macOS 10.15, *)
    final class ManualRig: @unchecked Sendable {
        let stream = ManualByteStream()
        let channel: SerialChannel
        let recorder: EventRecorder

        init(matcher: ReplyMatcher = TailScanMatcher(), defaultTimeout: TimeInterval = 5, gap: TimeInterval = 0) async {
            channel = SerialChannel(
                stream: stream,
                matcher: matcher,
                configuration: SerialChannel.Configuration(defaultTimeout: defaultTimeout, postTimeoutGap: gap)
            )
            recorder = await EventRecorder.attach(to: channel)
        }

        /// Starts `channel.open()` in a task and returns it once the stream has been asked to open.
        func beginOpening() async -> Task<Void, Error> {
            let asked = stream.openCalls
            let opening = Task { try await self.channel.open() }
            await waitUntil { self.stream.openCalls == asked + 1 }
            return opening
        }

        /// Opens the channel the way an asynchronous stream does: the stream reports when the test says so.
        func open() async throws {
            let opening = await beginOpening()
            stream.completeOpen()
            try await opening.value
        }

        func shutDown() async {
            await channel.close()
            recorder.stop()
        }
    }

#endif
