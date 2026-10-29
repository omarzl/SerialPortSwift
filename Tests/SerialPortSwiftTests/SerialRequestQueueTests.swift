//
//  SerialRequestQueueTests.swift
//  SerialPortSwiftTests
//

import SerialPortSwift
import SerialPortSwiftSimulation
import XCTest

// MARK: - Test doubles

/// Records what a queue tells its delegate, with the time and place of each call.
private final class TransportSpy: SerialTransportDelegate {
    enum Call: Equatable {
        case opened
        case closed(SerialCloseReason)
        case answered(Int, Data)
        case timedOut(Int)
        case encountered(SerialStreamError)
    }

    struct Record {
        let call: Call
        let date: Date
        let onMainThread: Bool
        let onQueue: Bool
    }

    private let lock = NSLock()
    private var recorded: [Record] = []
    private var hook: ((Call) -> Void)?
    private var exchanges: [SerialExchange] = []
    private let queueKey: DispatchSpecificKey<Bool>?

    init(queueKey: DispatchSpecificKey<Bool>? = nil) {
        self.queueKey = queueKey
    }

    /// Runs on the thread of each call, after it is recorded and with no lock held.
    var onCall: ((Call) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return hook
        }
        set {
            lock.lock()
            hook = newValue
            lock.unlock()
        }
    }

    var records: [Record] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var calls: [Call] {
        return records.map { $0.call }
    }

    /// The exchanges the delegate was told about, answered or not.
    var reportedExchanges: [SerialExchange] {
        lock.lock()
        defer { lock.unlock() }
        return exchanges
    }

    private func add(_ call: Call, exchange: SerialExchange? = nil) {
        var onQueue = false
        if let key = queueKey {
            onQueue = DispatchQueue.getSpecific(key: key) != nil
        }
        lock.lock()
        recorded.append(Record(call: call, date: Date(), onMainThread: Thread.isMainThread, onQueue: onQueue))
        if let exchange = exchange {
            exchanges.append(exchange)
        }
        let callback = hook
        lock.unlock()
        callback?(call)
    }

    func transportDidOpen(_ transport: SerialTransport) {
        add(.opened)
    }

    func transportDidClose(_ transport: SerialTransport, reason: SerialCloseReason) {
        add(.closed(reason))
    }

    func transport(_ transport: SerialTransport, didAnswer exchange: SerialExchange, with reply: Data) {
        add(.answered(exchange.id.number, reply), exchange: exchange)
    }

    func transport(_ transport: SerialTransport, didTimeOut exchange: SerialExchange) {
        add(.timedOut(exchange.id.number), exchange: exchange)
    }

    func transport(_ transport: SerialTransport, didEncounter error: SerialStreamError) {
        add(.encountered(error))
    }
}

/// What happened on a queue, without the bytes and times, so a test can compare sequences.
private enum Tag: Equatable {
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

/// Records every event a queue publishes.
private final class ObserverSpy: SerialQueueObserver {
    private let lock = NSLock()
    private var recorded: [SerialQueueEvent] = []
    private var threads: [Bool] = []
    private var hook: ((SerialQueueEvent) -> Void)?

    /// Runs on the queue's serial queue, for each event, after it is recorded and with no lock held.
    var onEvent: ((SerialQueueEvent) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return hook
        }
        set {
            lock.lock()
            hook = newValue
            lock.unlock()
        }
    }

    var events: [SerialQueueEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// For each event, whether it was published on the main thread.
    var publishedOnMainThread: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return threads
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

    /// The time between the first events tagged `start` and `end`, by the wall clock.
    func elapsed(from start: Tag, to end: Tag, file: StaticString = #file, line: UInt = #line) -> TimeInterval {
        guard let first = firstEvent(start), let second = firstEvent(end) else {
            XCTFail("Missing \(start) or \(end) in \(tags)", file: file, line: line)
            return 0
        }
        return second.date.timeIntervalSince(first.date)
    }

    func requestQueue(_ queue: SerialRequestQueue, didLog event: SerialQueueEvent) {
        lock.lock()
        recorded.append(event)
        threads.append(Thread.isMainThread)
        let callback = hook
        lock.unlock()
        callback?(event)
    }
}

/// Records the buffers a matcher is asked to scan, and never finds a reply.
private final class ScanLog {
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

private struct LoggingMatcher: ReplyMatcher {
    let log: ScanLog

    func verdict(on candidate: Data, expecting shape: ReplyShape) -> ReplyVerdict {
        return .rejected
    }

    func scan(_ buffer: Data, expecting shape: ReplyShape) -> ReplyScan {
        log.add(buffer)
        return ReplyScan(packet: nil, unreadable: nil)
    }
}

/// A stream the test drives by hand, to hold the queue in the states a synchronous stream skips.
private final class ManualByteStream: SerialByteStream {
    let name = "manual"
    weak var delegate: SerialByteStreamDelegate?

    private let lock = NSLock()
    private var opens = 0
    private var closes = 0
    private var written: [Data] = []
    private var report: SerialCloseReason?

    /// When set, `close()` reports this before it returns, as the streams in the package do for a stream
    /// that is open. By default it reports nothing: the test calls `completeClose` itself.
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
        lock.unlock()
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

/// A stream whose `open()` waits for the test before it finishes, the way a slow open does: a `close()`
/// from another thread can overtake it. It reports like the streams in the package: a close only if it
/// was open.
private final class LateOpeningStream: SerialByteStream {
    let name = "late"
    weak var delegate: SerialByteStreamDelegate?

    private let lock = NSLock()
    private var opened = false
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    /// Waits until `open()` has been called and is waiting.
    func waitUntilOpenIsWaiting() -> Bool {
        return entered.wait(timeout: .now() + 10) == .success
    }

    /// Lets the waiting `open()` finish.
    func finishOpening() {
        release.signal()
    }

    func open() {
        entered.signal()
        _ = release.wait(timeout: .now() + 10)
        lock.lock()
        let wasOpen = opened
        opened = true
        lock.unlock()
        if !wasOpen {
            delegate?.streamDidOpen(self)
        }
    }

    func close() {
        lock.lock()
        let wasOpen = opened
        opened = false
        lock.unlock()
        if wasOpen {
            delegate?.streamDidClose(self, reason: .requested)
        }
    }

    func write(_ bytes: Data) {}
}

/// A device that never answers.
private final class SilentDevice: SerialDeviceSimulator {
    func reply(to frame: Data) -> Data? {
        return nil
    }
}

/// A delegate that implements only what the protocol requires.
private final class MinimalDelegate: SerialTransportDelegate {
    func transportDidOpen(_ transport: SerialTransport) {}
    func transportDidClose(_ transport: SerialTransport, reason: SerialCloseReason) {}
    func transport(_ transport: SerialTransport, didAnswer exchange: SerialExchange, with reply: Data) {}
    func transport(_ transport: SerialTransport, didTimeOut exchange: SerialExchange) {}
}

/// A queue over a replay stream, with a delegate and an observer attached.
private final class Rig {
    let stream: ReplayByteStream
    let queue: SerialRequestQueue
    let delegate: TransportSpy
    let observer = ObserverSpy()

    init(
        script: [ReplayStep] = [],
        openFailure: SerialStreamError? = nil,
        matcher: ReplyMatcher = TailScanMatcher(),
        defaultTimeout: TimeInterval = 5,
        gap: TimeInterval = 0,
        maximumReplyLength: Int = 64,
        deliveryQueue: DispatchQueue = .main,
        deliveryKey: DispatchSpecificKey<Bool>? = nil,
        sharedQueue: DispatchQueue? = nil
    ) {
        stream = ReplayByteStream(script: script, openFailure: openFailure, queue: sharedQueue)
        queue = SerialRequestQueue(
            stream: stream,
            matcher: matcher,
            configuration: SerialRequestQueue.Configuration(
                defaultTimeout: defaultTimeout,
                maximumReplyLength: maximumReplyLength,
                postTimeoutGap: gap,
                deliveryQueue: deliveryQueue
            ),
            queue: sharedQueue
        )
        delegate = TransportSpy(queueKey: deliveryKey)
        queue.delegate = delegate
        queue.addObserver(observer)
    }

    var writtenFrames: [Data] {
        return stream.writes.map { $0.bytes }
    }
}

// MARK: - Tests

final class SerialRequestQueueTests: XCTestCase {
    private func ascii(_ string: String) -> Data {
        return Data(string.utf8)
    }

    private func exchange(
        _ number: Int,
        _ frame: String,
        reply: ReplyShape = .exactly(1),
        timeout: TimeInterval? = nil
    ) -> SerialExchange {
        return SerialExchange(id: SerialExchangeID(number: number), frame: ascii(frame), reply: reply, timeout: timeout)
    }

    private func id(_ number: Int) -> SerialExchangeID {
        return SerialExchangeID(number: number)
    }

    /// The matcher a filler-padding device needs: 0xFF is ignored, replies are ASCII and counted in
    /// characters.
    private var paddedMatcher: TailScanMatcher {
        return TailScanMatcher(fillerBytes: [0xFF], requiresASCII: true, lengthUnit: .characters)
    }

    /// Lets the main queue run for about `interval`, then returns.
    ///
    /// The run loop's own timeout can be lost on Linux (the call then blocks until something else
    /// wakes it, which may be never), so a block scheduled on the main queue is what ends the call.
    private func runMainQueue(for interval: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {}
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: interval + 1))
    }

    /// Runs the main queue until `condition` holds, failing the test after `timeout`.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 5,
        file: StaticString = #file,
        line: UInt = #line,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for a condition", file: file, line: line)
                return false
            }
            runMainQueue(for: 0.005)
        }
        return true
    }

    /// Runs the main queue for `seconds`, to let anything that should not happen have its chance.
    private func settle(_ seconds: TimeInterval) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            runMainQueue(for: min(0.01, max(0.001, end.timeIntervalSinceNow)))
        }
    }

    // MARK: Order and the wire

    func testItWritesInSubmissionOrderAndAWriteWaitsForTheExchangeAheadOfIt() {
        let rig = Rig(script: [.silence(), .silence(), .silence()])
        rig.queue.open()

        rig.queue.send(exchange(1, "1"))
        rig.queue.sendWithoutReply(ascii("w"))
        rig.queue.send(exchange(2, "2"))
        waitUntil { rig.stream.writes.count == 1 }
        settle(0.1)

        XCTAssertEqual(rig.writtenFrames, [ascii("1")])

        rig.stream.receive(ascii("A"))
        waitUntil { rig.stream.writes.count == 3 }

        XCTAssertEqual(rig.writtenFrames, [ascii("1"), ascii("w"), ascii("2")])

        rig.stream.receive(ascii("B"))
        waitUntil { rig.delegate.calls.count == 3 }

        XCTAssertEqual(rig.delegate.calls, [.opened, .answered(1, ascii("A")), .answered(2, ascii("B"))])
        XCTAssertEqual(rig.stream.writes.map { $0.matchedExpectation }, [true, true, true])
    }

    func testWritesWithoutAReplyGoOutBackToBackInOrder() {
        let rig = Rig(script: [.silence(), .silence(), .silence()])
        rig.queue.open()

        rig.queue.sendWithoutReply(ascii("a"))
        rig.queue.sendWithoutReply(ascii("b"))
        rig.queue.sendWithoutReply(ascii("c"))
        waitUntil { rig.stream.writes.count == 3 }

        XCTAssertEqual(rig.writtenFrames, [ascii("a"), ascii("b"), ascii("c")])
        XCTAssertEqual(rig.observer.tagsWithoutRaw, [.opened, .sent(nil), .sent(nil), .sent(nil)])
        XCTAssertEqual(rig.observer.events.compactMap { $0.bytes }, [ascii("a"), ascii("b"), ascii("c")])
    }

    func testOnlyOneExchangeIsOnTheWireAtATime() {
        let rig = Rig(script: [.silence(), .silence()])
        rig.queue.open()

        rig.queue.send(exchange(1, "1"))
        rig.queue.send(exchange(2, "2"))
        waitUntil { rig.stream.writes.count == 1 }
        settle(0.1)

        XCTAssertEqual(rig.writtenFrames, [ascii("1")])
        XCTAssertFalse(rig.observer.has(.sent(2)))

        rig.stream.receive(ascii("A"))
        waitUntil { rig.observer.has(.sent(2)) }
        waitUntil { rig.stream.writes.count == 2 }

        XCTAssertEqual(rig.observer.tagsWithoutRaw, [.opened, .sent(1), .answered(1), .sent(2)])
        XCTAssertEqual(rig.writtenFrames, [ascii("1"), ascii("2")])
    }

    func testTheFrameIsPublishedAsSent() {
        let rig = Rig(script: [.silence()])
        rig.queue.open()

        rig.queue.send(exchange(4, "frame"))
        waitUntil { rig.observer.has(.sent(4)) }

        XCTAssertEqual(rig.observer.firstEvent(.sent(4))?.bytes, ascii("frame"))
    }

    // MARK: Answers

    func testAnAnswerIsDeliveredRawOnTheMainQueueWithItsExchange() {
        let rig = Rig(script: [.reply(with: [ReplayChunk(ascii("OK"), at: 0.1)])])
        rig.queue.open()

        rig.queue.send(exchange(7, "q", reply: .exactly(2)))
        waitUntil { rig.delegate.calls.count == 2 }

        XCTAssertEqual(rig.delegate.calls, [.opened, .answered(7, ascii("OK"))])
        XCTAssertTrue(rig.delegate.records[1].onMainThread)
        XCTAssertEqual(rig.delegate.reportedExchanges.map { $0.id }, [id(7)])
        XCTAssertEqual(rig.delegate.reportedExchanges.map { $0.frame }, [ascii("q")])
    }

    func testTheRoundTripRunsFromTheWriteToTheReply() {
        let offset: TimeInterval = 0.1
        let rig = Rig(script: [.reply(with: [ReplayChunk(ascii("OK"), at: offset)])])
        rig.queue.open()

        rig.queue.send(exchange(7, "q", reply: .exactly(2)))
        waitUntil { rig.observer.has(.answered(7)) }

        guard let event = rig.observer.firstEvent(.answered(7)), case .answered(_, let roundTrip) = event.kind else {
            return XCTFail("No answer published")
        }
        // The stream times the offset from its own write, a moment before the queue notes the write.
        XCTAssertGreaterThanOrEqual(roundTrip, offset - 0.02)
        XCTAssertLessThan(roundTrip, offset + 2)
        XCTAssertEqual(event.bytes, ascii("OK"))
    }

    func testTheReplyOfAnAnythingExchangeIsTheFirstByte() {
        let rig = Rig(script: [.reply(with: [ReplayChunk(ascii("xyz"), at: 0.02)])])
        rig.queue.open()

        rig.queue.send(exchange(1, "q", reply: .anything))
        waitUntil { rig.delegate.calls.count == 2 }
        waitUntil { rig.observer.has(.unsolicited) }

        XCTAssertEqual(rig.delegate.calls, [.opened, .answered(1, ascii("x"))])
        XCTAssertEqual(rig.observer.firstEvent(.unsolicited)?.bytes, ascii("yz"))
    }

    // MARK: Timeouts

    func testAnExchangeTimesOutAtItsOwnTimeoutWhenThatIsLongerThanTheDefault() {
        let rig = Rig(script: [.silence()], defaultTimeout: 0.15)
        rig.queue.open()

        rig.queue.send(exchange(1, "q", timeout: 0.4))
        waitUntil { rig.delegate.calls.count == 2 }

        XCTAssertEqual(rig.delegate.calls, [.opened, .timedOut(1)])
        XCTAssertTrue(rig.delegate.records[1].onMainThread)
        XCTAssertGreaterThanOrEqual(rig.observer.elapsed(from: .sent(1), to: .timedOut(1)), 0.4 - 0.01)
        XCTAssertEqual(rig.observer.firstEvent(.timedOut(1))?.bytes, ascii("q"))
        XCTAssertEqual(rig.delegate.reportedExchanges.map { $0.frame }, [ascii("q")])
    }

    func testAnExchangeWithoutATimeoutUsesTheDefault() {
        let rig = Rig(script: [.silence()], defaultTimeout: 0.2)
        rig.queue.open()

        rig.queue.send(exchange(1, "q"))
        waitUntil { rig.delegate.calls.count == 2 }

        XCTAssertEqual(rig.delegate.calls, [.opened, .timedOut(1)])
        XCTAssertGreaterThanOrEqual(rig.observer.elapsed(from: .sent(1), to: .timedOut(1)), 0.2 - 0.01)
        XCTAssertEqual(rig.queue.defaultTimeout, 0.2)
    }

    func testAShorterOwnTimeoutBeatsALaterReply() {
        let rig = Rig(script: [.reply(with: [ReplayChunk(ascii("A"), at: 0.3)])], defaultTimeout: 5)
        rig.queue.open()

        rig.queue.send(exchange(1, "q", timeout: 0.05))
        waitUntil { rig.delegate.calls.count == 2 }
        // The reply, due 0.3 s after the write, finds nothing on the wire.
        waitUntil { rig.observer.has(.unsolicited) }
        settle(0.05)

        XCTAssertEqual(rig.delegate.calls, [.opened, .timedOut(1)])
        XCTAssertEqual(rig.observer.tagsWithoutRaw, [.opened, .sent(1), .timedOut(1), .unsolicited])
    }

    func testTheNextExchangeIsWrittenAfterATimeout() {
        let rig = Rig(script: [.silence(), .reply(with: [ReplayChunk(ascii("B"), at: 0.02)])], gap: 0)
        rig.queue.open()

        rig.queue.send(exchange(1, "1", timeout: 0.05))
        rig.queue.send(exchange(2, "2"))
        waitUntil { rig.delegate.calls.count == 3 }

        XCTAssertEqual(rig.delegate.calls, [.opened, .timedOut(1), .answered(2, ascii("B"))])
    }

    // MARK: The pause after a timeout

    func testALateReplyInsideTheGapIsNotCreditedToTheNextExchange() {
        let gap: TimeInterval = 0.4
        let rig = Rig(script: [.silence(), .reply(with: [ReplayChunk(ascii("B"), at: 0.05)])], gap: gap)
        // The late byte arrives well inside the pause that follows the timeout.
        rig.observer.onEvent = { [weak rig] event in
            if event.kind == .timedOut(SerialExchangeID(number: 1)) {
                rig?.stream.receive(Data("L".utf8), after: 0.05)
            }
        }
        rig.queue.open()

        rig.queue.send(exchange(1, "1", timeout: 0.15))
        rig.queue.send(exchange(2, "2"))
        waitUntil { rig.delegate.calls.count == 3 }

        XCTAssertEqual(rig.delegate.calls, [.opened, .timedOut(1), .answered(2, ascii("B"))])
        XCTAssertEqual(
            rig.observer.tagsWithoutRaw,
            [.opened, .sent(1), .timedOut(1), .late, .sent(2), .answered(2)]
        )
        XCTAssertEqual(rig.observer.firstEvent(.late)?.bytes, ascii("L"))
        XCTAssertGreaterThanOrEqual(rig.observer.elapsed(from: .timedOut(1), to: .sent(2)), gap - 0.01)
    }

    func testAZeroGapWritesTheNextExchangeRightAfterATimeout() {
        let rig = Rig(script: [.silence(), .silence()], gap: 2)
        rig.queue.open()
        XCTAssertEqual(rig.queue.postTimeoutGap, 2)
        rig.queue.postTimeoutGap = 0
        XCTAssertEqual(rig.queue.postTimeoutGap, 0)

        rig.queue.send(exchange(1, "1", timeout: 0.1))
        rig.queue.send(exchange(2, "2", timeout: 5))
        waitUntil { rig.observer.has(.sent(2)) }

        XCTAssertLessThan(rig.observer.elapsed(from: .timedOut(1), to: .sent(2)), 1)
    }

    func testChangingTheGapAppliesFromTheNextTimeout() {
        let gap: TimeInterval = 0.4
        let rig = Rig(script: [.silence(), .silence(), .silence()], gap: 0)
        rig.queue.open()
        // The first timeout is over by the time the delegate hears of it; the change is for the next.
        rig.delegate.onCall = { [weak rig] call in
            if call == .timedOut(1) {
                rig?.queue.postTimeoutGap = gap
            }
        }

        rig.queue.send(exchange(1, "1", timeout: 0.1))
        rig.queue.send(exchange(2, "2", timeout: 0.4))
        rig.queue.send(exchange(3, "3", timeout: 5))
        waitUntil { rig.observer.has(.sent(3)) }

        XCTAssertEqual(rig.queue.postTimeoutGap, gap)
        XCTAssertGreaterThanOrEqual(rig.observer.elapsed(from: .timedOut(2), to: .sent(3)), gap - 0.01)
    }

    // MARK: Filler and what the observer sees

    func testAnInjectedFillerByteIsVisibleRawWithItsTimestampAndLeftOutOfTheReply() {
        let rig = Rig(script: [.silence()], matcher: paddedMatcher)
        rig.queue.open()
        rig.queue.send(exchange(1, "q"))
        waitUntil { rig.observer.has(.sent(1)) }

        let before = Date()
        rig.stream.receive(Data([0xFF, 0x43]))
        waitUntil { rig.delegate.calls.count == 2 }
        let after = Date()

        guard let raw = rig.observer.firstEvent(.raw) else {
            return XCTFail("No raw event")
        }
        XCTAssertEqual(raw.bytes, Data([0xFF, 0x43]))
        XCTAssertGreaterThanOrEqual(raw.date, before)
        XCTAssertLessThanOrEqual(raw.date, after)
        XCTAssertEqual(rig.delegate.calls, [.opened, .answered(1, Data([0x43]))])
        XCTAssertEqual(rig.observer.firstEvent(.answered(1))?.bytes, Data([0x43]))
    }

    func testTheRawEventComesBeforeAnythingDecidedAboutTheBytes() {
        let rig = Rig(script: [.silence()], matcher: paddedMatcher)
        rig.queue.open()
        rig.queue.send(exchange(1, "q"))
        waitUntil { rig.observer.has(.sent(1)) }

        rig.stream.receive(Data([0xFF, 0x43]))
        waitUntil { rig.observer.has(.answered(1)) }

        XCTAssertEqual(rig.observer.tags, [.opened, .sent(1), .raw, .answered(1)])
    }

    func testFillerAfterTheReplyInTheSameChunkIsDroppedWithTheRestOfIt() {
        // The reply is complete at its last byte, so what follows in the chunk is not part of it.
        let rig = Rig(script: [.silence()], matcher: paddedMatcher)
        rig.queue.open()
        rig.queue.send(exchange(1, "q"))
        waitUntil { rig.observer.has(.sent(1)) }

        rig.stream.receive(Data([0x43, 0xFF]))
        waitUntil { rig.observer.has(.unsolicited) }
        waitUntil { rig.delegate.calls.count == 2 }

        XCTAssertEqual(rig.delegate.calls, [.opened, .answered(1, Data([0x43]))])
        XCTAssertEqual(rig.observer.firstEvent(.unsolicited)?.bytes, Data([0xFF]))
    }

    func testFillerInsideTheReplyStaysInItRaw() {
        let rig = Rig(script: [.silence()], matcher: paddedMatcher)
        rig.queue.open()
        rig.queue.send(exchange(1, "q", reply: .exactly(2)))
        waitUntil { rig.observer.has(.sent(1)) }

        rig.stream.receive(Data([0x41, 0xFF, 0x42]))
        waitUntil { rig.delegate.calls.count == 2 }

        XCTAssertEqual(rig.delegate.calls, [.opened, .answered(1, Data([0x41, 0xFF, 0x42]))])
    }

    func testCharactersFindAReplyAtItsCarriageReturnAndTheLineFeedArrivesWithNothingInFlight() {
        let matcher = TailScanMatcher(lengthUnit: .characters)
        let rig = Rig(
            script: [.reply(with: [ReplayChunk(ascii("OK\r"), at: 0.02), ReplayChunk(ascii("\n"), at: 0.1)])],
            matcher: matcher
        )
        rig.queue.open()

        rig.queue.send(exchange(1, "q", reply: .exactly(3)))
        waitUntil { rig.observer.has(.unsolicited) }

        XCTAssertEqual(rig.delegate.calls, [.opened, .answered(1, ascii("OK\r"))])
        XCTAssertEqual(rig.observer.firstEvent(.unsolicited)?.bytes, ascii("\n"))
        XCTAssertEqual(rig.observer.tagsWithoutRaw, [.opened, .sent(1), .answered(1), .unsolicited])
    }

    func testBytesTakeTheWholeCarriageReturnLineFeedEnding() {
        let matcher = TailScanMatcher(lengthUnit: .bytes)
        let rig = Rig(
            script: [.reply(with: [ReplayChunk(ascii("OK\r"), at: 0.02), ReplayChunk(ascii("\n"), at: 0.1)])],
            matcher: matcher
        )
        rig.queue.open()

        rig.queue.send(exchange(1, "q", reply: .exactly(4)))
        waitUntil { rig.delegate.calls.count == 2 }
        settle(0.1)

        XCTAssertEqual(rig.delegate.calls, [.opened, .answered(1, ascii("OK\r\n"))])
        XCTAssertFalse(rig.observer.has(.unsolicited))
    }

    func testANonASCIIByteIsPublishedAsAnUnreadableCandidate() {
        let rig = Rig(script: [.silence()], matcher: paddedMatcher)
        rig.queue.open()
        rig.queue.send(exchange(1, "q", reply: .exactly(2), timeout: 0.3))
        waitUntil { rig.observer.has(.sent(1)) }

        rig.stream.receive(Data([0x80, 0x43]))
        waitUntil { rig.delegate.calls.count == 2 }

        XCTAssertEqual(rig.delegate.calls, [.opened, .timedOut(1)])
        XCTAssertEqual(
            rig.observer.tagsWithoutRaw,
            [.opened, .sent(1), .unreadable(1), .unreadable(1), .timedOut(1)]
        )
        let unreadable = rig.observer.events.filter { Tag($0.kind) == .unreadable(1) }.map { $0.bytes }
        XCTAssertEqual(unreadable, [Data([0x80]), Data([0x80, 0x43])])
    }

    // MARK: The reply buffer

    func testTheReplyBufferIsBoundedAndKeepsTheLatestBytes() {
        let log = ScanLog()
        let rig = Rig(script: [.silence()], matcher: LoggingMatcher(log: log), maximumReplyLength: 4)
        rig.queue.open()
        rig.queue.send(exchange(1, "q", reply: .exactly(3)))
        waitUntil { rig.observer.has(.sent(1)) }

        rig.stream.receive(Data([1, 2, 3, 4, 5, 6]))
        rig.stream.receive(Data([7, 8]))
        waitUntil { log.buffers.count == 8 }

        XCTAssertEqual(log.buffers, [
            Data([1]), Data([1, 2]), Data([1, 2, 3]), Data([1, 2, 3, 4]),
            Data([2, 3, 4, 5]), Data([3, 4, 5, 6]), Data([4, 5, 6, 7]), Data([5, 6, 7, 8])
        ])
        XCTAssertTrue(log.buffers.allSatisfy { $0.count <= 4 })
        XCTAssertTrue(log.startIndexes.allSatisfy { $0 == 0 })
    }

    func testAnExactLengthLongerThanTheLimitKeepsEnoughBytesToBeFound() {
        let log = ScanLog()
        let rig = Rig(script: [.silence()], matcher: LoggingMatcher(log: log), maximumReplyLength: 4)
        rig.queue.open()
        rig.queue.send(exchange(1, "q", reply: .exactly(6)))
        waitUntil { rig.observer.has(.sent(1)) }

        rig.stream.receive(Data([1, 2, 3, 4, 5, 6, 7, 8]))
        waitUntil { log.buffers.count == 8 }

        XCTAssertEqual(log.buffers, [
            Data([1]), Data([1, 2]), Data([1, 2, 3]), Data([1, 2, 3, 4]), Data([1, 2, 3, 4, 5]),
            Data([1, 2, 3, 4, 5, 6]), Data([2, 3, 4, 5, 6, 7]), Data([3, 4, 5, 6, 7, 8])
        ])
    }

    func testAnExchangeThatExpectsMoreThanTheDefaultLimitIsAnswered() {
        let reply = Data((0..<100).map { UInt8($0) })
        let rig = Rig(script: [
            .reply(with: [ReplayChunk(reply.prefix(60), at: 0.02), ReplayChunk(reply.suffix(40), at: 0.04)])
        ])
        XCTAssertEqual(rig.queue.configuration.maximumReplyLength, 64)
        rig.queue.open()

        rig.queue.send(exchange(1, "q", reply: .exactly(100)))
        waitUntil { rig.delegate.calls.count == 2 }

        XCTAssertEqual(rig.delegate.calls, [.opened, .answered(1, reply)])
        XCTAssertEqual(rig.observer.tagsWithoutRaw, [.opened, .sent(1), .answered(1)])
    }

    func testTheLimitStillAppliesToExchangesThatNeedLess() {
        let log = ScanLog()
        let rig = Rig(script: [.silence()], matcher: LoggingMatcher(log: log), maximumReplyLength: 4)
        rig.queue.open()
        rig.queue.send(exchange(1, "q", reply: .anything))
        waitUntil { rig.observer.has(.sent(1)) }

        rig.stream.receive(Data([1, 2, 3, 4, 5, 6]))
        waitUntil { log.buffers.count == 6 }

        XCTAssertTrue(log.buffers.allSatisfy { $0.count <= 4 })
    }

    func testTheBufferStartsEmptyForEachExchange() {
        let log = ScanLog()
        let rig = Rig(script: [.silence(), .silence()], matcher: LoggingMatcher(log: log))
        rig.queue.open()
        rig.queue.send(exchange(1, "1", timeout: 0.4))
        rig.queue.send(exchange(2, "2", timeout: 5))
        waitUntil { rig.observer.has(.sent(1)) }
        rig.stream.receive(Data([1, 2]))
        waitUntil { rig.observer.has(.sent(2)) }
        rig.stream.receive(Data([3]))
        waitUntil { log.buffers.count == 3 }

        XCTAssertEqual(log.buffers, [Data([1]), Data([1, 2]), Data([3])])
    }

    func testBytesLeftInAChunkAfterTheReplyAreDroppedNotGivenToTheNextExchange() {
        let rig = Rig(script: [
            .reply(with: [ReplayChunk(ascii("CXY"), at: 0.05)]),
            .reply(with: [ReplayChunk(ascii("Q"), at: 0.2)])
        ])
        rig.queue.open()

        rig.queue.send(exchange(1, "1"))
        rig.queue.send(exchange(2, "2"))
        waitUntil { rig.delegate.calls.count == 3 }

        XCTAssertEqual(rig.delegate.calls, [.opened, .answered(1, ascii("C")), .answered(2, ascii("Q"))])
        XCTAssertEqual(
            rig.observer.tagsWithoutRaw,
            [.opened, .sent(1), .answered(1), .unsolicited, .sent(2), .answered(2)]
        )
        XCTAssertEqual(rig.observer.firstEvent(.unsolicited)?.bytes, ascii("XY"))
    }

    func testBytesWithNothingInFlightAreDroppedAsUnsolicited() {
        let rig = Rig()
        rig.queue.open()

        rig.stream.receive(ascii("zz"))
        waitUntil { rig.observer.has(.unsolicited) }

        XCTAssertEqual(rig.observer.tags, [.opened, .raw, .unsolicited])
        XCTAssertEqual(rig.observer.firstEvent(.raw)?.bytes, ascii("zz"))
        XCTAssertEqual(rig.observer.firstEvent(.unsolicited)?.bytes, ascii("zz"))
        XCTAssertEqual(rig.delegate.calls, [.opened])
    }

    func testBytesBeforeAnExchangeIsWrittenAreNotItsReply() {
        let rig = Rig(script: [.silence()])
        rig.queue.open()
        rig.stream.receive(ascii("early"))
        waitUntil { rig.observer.has(.unsolicited) }

        rig.queue.send(exchange(1, "q", timeout: 0.15))
        waitUntil { rig.delegate.calls.count == 2 }

        XCTAssertEqual(rig.delegate.calls, [.opened, .timedOut(1)])
    }

    // MARK: Cancelling

    func testCancellingDropsTheQueuedExchangesAndKeepsTheWritesAndTheOneOnTheWire() {
        let rig = Rig(script: [.silence(), .silence()])
        rig.queue.open()
        rig.queue.send(exchange(1, "1"))
        rig.queue.send(exchange(2, "2"))
        rig.queue.send(exchange(3, "3"))
        rig.queue.sendWithoutReply(ascii("w"))

        let cancelled = rig.queue.cancelQueuedExchanges()

        XCTAssertEqual(cancelled, [id(2), id(3)])
        waitUntil { rig.stream.writes.count == 1 }
        XCTAssertEqual(rig.writtenFrames, [ascii("1")])

        rig.stream.receive(ascii("A"))
        waitUntil { rig.stream.writes.count == 2 }
        settle(0.1)

        XCTAssertEqual(rig.writtenFrames, [ascii("1"), ascii("w")])
        XCTAssertEqual(rig.delegate.calls, [.opened, .answered(1, ascii("A"))])
        XCTAssertEqual(
            rig.observer.tagsWithoutRaw,
            [.opened, .sent(1), .cancelled([2, 3]), .answered(1), .sent(nil)]
        )
    }

    func testCancellingWithNothingToCancelAnswersNothingAndPublishesNothing() {
        let rig = Rig(script: [.silence(), .silence()])
        rig.queue.open()
        rig.queue.send(exchange(1, "1"))
        rig.queue.sendWithoutReply(ascii("w"))

        XCTAssertEqual(rig.queue.cancelQueuedExchanges(), [])
        XCTAssertEqual(rig.queue.cancelQueuedExchanges(), [])
        waitUntil { rig.observer.has(.sent(1)) }

        XCTAssertFalse(rig.observer.tags.contains { if case .cancelled = $0 { return true } else { return false } })
    }

    func testCancellingTheQueuedExchangesBehindAPauseMakesTheQueueIdle() {
        let rig = Rig(script: [.silence(), .silence()], gap: 3)
        rig.queue.open()
        rig.queue.send(exchange(1, "1", timeout: 0.05))
        rig.queue.send(exchange(2, "2"))
        waitUntil { rig.delegate.calls.contains(.timedOut(1)) }
        var idle = false
        rig.queue.whenIdle { idle = true }
        settle(0.05)
        XCTAssertFalse(idle)

        let cancelled = rig.queue.cancelQueuedExchanges()

        XCTAssertEqual(cancelled, [id(2)])
        waitUntil { idle }
        XCTAssertFalse(rig.observer.has(.sent(2)))
    }

    // MARK: Closing

    func testCloseOnTheMainThreadReportsBeforeItReturnsAndDropsWhatWasInFlight() {
        let rig = Rig(script: [.reply(with: [ReplayChunk(ascii("A"), at: 0.1)])])
        rig.queue.open()
        rig.queue.send(exchange(1, "1", timeout: 0.2))
        rig.queue.send(exchange(2, "2"))
        waitUntil { rig.stream.writes.count == 1 }

        rig.queue.close()

        XCTAssertEqual(rig.delegate.calls, [.opened, .closed(.requested)])
        XCTAssertFalse(rig.queue.isOpen)
        settle(0.5)

        XCTAssertEqual(rig.delegate.calls, [.opened, .closed(.requested)])
        XCTAssertEqual(rig.observer.tags, [.opened, .sent(1), .closed(.requested)])
        XCTAssertEqual(rig.writtenFrames, [ascii("1")])
    }

    func testClosingTwiceReportsOnce() {
        let rig = Rig()
        rig.queue.open()

        rig.queue.close()
        rig.queue.close()
        settle(0.05)

        XCTAssertEqual(rig.delegate.calls, [.opened, .closed(.requested)])
    }

    func testClosingAClosedQueueDoesNothing() {
        let rig = Rig()

        rig.queue.close()
        settle(0.05)

        XCTAssertEqual(rig.delegate.calls, [])
        XCTAssertEqual(rig.observer.tags, [])
    }

    func testAnAnswerQueuedForDeliveryBeforeACloseIsNotDeliveredAfterIt() {
        let rig = Rig(script: [.silence()])
        let published = DispatchSemaphore(value: 0)
        rig.observer.onEvent = { event in
            if Tag(event.kind) == .answered(1) {
                published.signal()
            }
        }
        rig.queue.open()
        rig.queue.send(exchange(1, "1"))
        waitUntil { rig.observer.has(.sent(1)) }

        // Main stays busy until the answer is published, so its delivery waits in the main queue.
        rig.stream.receive(ascii("A"))
        XCTAssertEqual(published.wait(timeout: .now() + 5), .success)
        rig.queue.close()
        settle(0.2)

        XCTAssertEqual(rig.delegate.calls, [.opened, .closed(.requested)])
    }

    func testATimeoutQueuedForDeliveryBeforeACloseIsNotDeliveredAfterIt() {
        let rig = Rig(script: [.silence()])
        let published = DispatchSemaphore(value: 0)
        rig.observer.onEvent = { event in
            if Tag(event.kind) == .timedOut(1) {
                published.signal()
            }
        }
        rig.queue.open()
        rig.queue.send(exchange(1, "1", timeout: 0.05))
        waitUntil { rig.observer.has(.sent(1)) }

        XCTAssertEqual(published.wait(timeout: .now() + 5), .success)
        rig.queue.close()
        settle(0.2)

        XCTAssertEqual(rig.delegate.calls, [.opened, .closed(.requested)])
    }

    func testAStreamThatEndsAsRemovedClosesTheQueueOnce() {
        let rig = Rig(script: [.silence()])
        rig.queue.open()
        rig.queue.send(exchange(1, "1", timeout: 0.3))
        waitUntil { rig.observer.has(.sent(1)) }

        rig.stream.end(.removed, after: 0.02)
        waitUntil { rig.delegate.calls.count == 2 }
        settle(0.5)
        rig.queue.close()
        settle(0.05)

        XCTAssertEqual(rig.delegate.calls, [.opened, .closed(.removed)])
        XCTAssertFalse(rig.queue.isOpen)
        XCTAssertEqual(rig.observer.tags, [.opened, .sent(1), .closed(.removed)])
    }

    func testAStreamThatFailsWhileOpenClosesTheQueueWithTheFailure() {
        let failure = SerialStreamError.readFailed(code: 5)
        let rig = Rig()
        rig.queue.open()

        rig.stream.end(.failed(failure), after: 0)
        waitUntil { rig.delegate.calls.count == 2 }

        XCTAssertEqual(rig.delegate.calls, [.opened, .closed(.failed(failure))])
        XCTAssertFalse(rig.queue.isOpen)
    }

    func testAnOpenFailureClosesTheQueueWithTheFailureAndNeverOpens() {
        let failure = SerialStreamError.openFailed(path: "/dev/none", code: 2)
        let rig = Rig(openFailure: failure)

        rig.queue.open()

        XCTAssertEqual(rig.delegate.calls, [.closed(.failed(failure))])
        XCTAssertFalse(rig.queue.isOpen)
        rig.queue.send(exchange(1, "1"))
        settle(0.1)
        XCTAssertEqual(rig.delegate.calls, [.closed(.failed(failure))])
        XCTAssertEqual(rig.observer.tags, [.closed(.failed(failure))])
        XCTAssertEqual(rig.stream.writes, [])
    }

    func testCloseThenReopenWorksAgainAndNothingFromBeforeTheCloseLeaksIn() {
        let rig = Rig(script: [.reply(with: [ReplayChunk(ascii("OLD"), at: 0.3)])])
        rig.queue.open()
        rig.queue.send(exchange(1, "1", timeout: 0.2))
        rig.queue.send(exchange(2, "2"))
        waitUntil { rig.stream.writes.count == 1 }

        rig.queue.close()
        XCTAssertFalse(rig.queue.isOpen)
        rig.stream.append([.reply(with: [ReplayChunk(ascii("N"), at: 0.5)])])
        rig.queue.open()
        XCTAssertTrue(rig.queue.isOpen)
        rig.queue.send(exchange(3, "3", timeout: 5))
        waitUntil { rig.delegate.calls.contains(.answered(3, ascii("N"))) }

        // Neither the first exchange's timer (0.2 s) nor its reply (0.3 s) reached the new one.
        XCTAssertEqual(rig.delegate.calls, [.opened, .closed(.requested), .opened, .answered(3, ascii("N"))])
        XCTAssertEqual(rig.writtenFrames, [ascii("1"), ascii("3")])
        XCTAssertFalse(rig.observer.has(.timedOut(1)))
        XCTAssertFalse(rig.observer.has(.timedOut(3)))
    }

    // MARK: Opening

    func testOpenOnTheMainThreadWithASynchronousStreamReportsBeforeItReturns() {
        let rig = Rig()
        XCTAssertFalse(rig.queue.isOpen)

        rig.queue.open()

        XCTAssertEqual(rig.delegate.calls, [.opened])
        XCTAssertTrue(rig.delegate.records[0].onMainThread)
        XCTAssertTrue(rig.queue.isOpen)
        XCTAssertEqual(rig.observer.tags, [.opened])

        rig.queue.open()
        settle(0.05)
        XCTAssertEqual(rig.delegate.calls, [.opened])
    }

    func testTheDelegateIsToldOnTheConfiguredDeliveryQueue() {
        let key = DispatchSpecificKey<Bool>()
        let delivery = DispatchQueue(label: "SerialRequestQueueTests.delivery")
        delivery.setSpecific(key: key, value: true)
        let rig = Rig(
            script: [.reply(with: [ReplayChunk(ascii("A"), at: 0.02)]), .silence()],
            deliveryQueue: delivery,
            deliveryKey: key
        )

        rig.queue.open()
        rig.queue.send(exchange(1, "1"))
        rig.queue.send(exchange(2, "2", timeout: 0.1))
        waitUntil { rig.delegate.calls.count == 3 }
        rig.queue.close()
        waitUntil { rig.delegate.calls.count == 4 }

        XCTAssertEqual(
            rig.delegate.calls,
            [.opened, .answered(1, ascii("A")), .timedOut(2), .closed(.requested)]
        )
        XCTAssertTrue(rig.delegate.records.allSatisfy { $0.onQueue && !$0.onMainThread })
    }

    func testItNamesItselfAfterTheStreamAndIsNotTheStreamsDelegate() {
        let rig = Rig()

        XCTAssertEqual(rig.queue.name, "replay")
        XCTAssertNotNil(rig.stream.delegate)
        XCTAssertNil((rig.queue as AnyObject) as? SerialByteStreamDelegate)
        XCTAssertTrue(rig.queue.stream === rig.stream)
    }

    func testASendWhileOpeningIsKeptAndWrittenOnceTheStreamHasOpened() {
        let manual = ManualByteStream()
        let queue = SerialRequestQueue(stream: manual, configuration: SerialRequestQueue.Configuration(defaultTimeout: 5))
        let delegate = TransportSpy()
        queue.delegate = delegate

        queue.open()
        queue.open()
        queue.send(exchange(1, "1"))
        queue.sendWithoutReply(ascii("w"))
        settle(0.1)

        XCTAssertEqual(manual.openCalls, 1)
        XCTAssertFalse(queue.isOpen)
        XCTAssertEqual(manual.writes, [])

        manual.completeOpen()
        XCTAssertEqual(delegate.calls, [.opened])
        XCTAssertTrue(queue.isOpen)
        waitUntil { manual.writes.count == 1 }
        settle(0.05)

        XCTAssertEqual(manual.writes, [ascii("1")])
        manual.deliver(ascii("A"))
        waitUntil { manual.writes.count == 2 }
        XCTAssertEqual(manual.writes, [ascii("1"), ascii("w")])
    }

    func testClosingWhileOpeningClosesAtOnceAsTheStreamHasNothingToReport() {
        let manual = ManualByteStream()
        let queue = SerialRequestQueue(stream: manual)
        let delegate = TransportSpy()
        let observer = ObserverSpy()
        queue.delegate = delegate
        queue.addObserver(observer)
        queue.open()

        queue.close()

        XCTAssertEqual(manual.openCalls, 1)
        XCTAssertEqual(manual.closeCalls, 1)
        XCTAssertEqual(delegate.calls, [.closed(.requested)])
        XCTAssertEqual(observer.tags, [.closed(.requested)])
        XCTAssertFalse(queue.isOpen)

        // The queue is not stuck: it opens again.
        queue.open()
        XCTAssertEqual(manual.openCalls, 2)
        manual.completeOpen()
        XCTAssertEqual(delegate.calls, [.closed(.requested), .opened])
        XCTAssertTrue(queue.isOpen)
    }

    func testClosingWhileOpeningReportsOnceWhenTheStreamReportsTheCloseToo() {
        let manual = ManualByteStream()
        manual.closeReport = .requested
        let queue = SerialRequestQueue(stream: manual)
        let delegate = TransportSpy()
        queue.delegate = delegate
        queue.open()

        queue.close()
        manual.completeClose(.requested)

        XCTAssertEqual(delegate.calls, [.closed(.requested)])
        XCTAssertFalse(queue.isOpen)
    }

    func testAnOpenThatCompletesAfterTheQueueWasClosedClosesTheStreamAgain() {
        let manual = ManualByteStream()
        let queue = SerialRequestQueue(stream: manual)
        let delegate = TransportSpy()
        queue.delegate = delegate
        queue.open()
        queue.close()

        manual.completeOpen()

        XCTAssertEqual(manual.closeCalls, 2)
        XCTAssertEqual(delegate.calls, [.closed(.requested)])
        XCTAssertFalse(queue.isOpen)

        // What the stream reports for that second close changes nothing.
        manual.completeClose(.requested)
        XCTAssertEqual(delegate.calls, [.closed(.requested)])
        queue.open()
        XCTAssertEqual(manual.openCalls, 2)
    }

    func testAnOpenThatCompletesWhileTheQueueIsClosingClosesTheStreamAgain() {
        let manual = ManualByteStream()
        let queue = SerialRequestQueue(stream: manual)
        let delegate = TransportSpy()
        queue.delegate = delegate
        queue.open()
        manual.completeOpen()
        queue.close()
        XCTAssertEqual(delegate.calls, [.opened])

        manual.completeOpen()

        XCTAssertEqual(manual.closeCalls, 2)
        XCTAssertEqual(delegate.calls, [.opened])
        manual.completeClose(.requested)
        manual.completeClose(.requested)
        XCTAssertEqual(delegate.calls, [.opened, .closed(.requested)])
        XCTAssertFalse(queue.isOpen)
    }

    func testAnOpenReportedTwiceOpensTheQueueOnce() {
        let manual = ManualByteStream()
        let queue = SerialRequestQueue(stream: manual)
        let delegate = TransportSpy()
        queue.delegate = delegate
        queue.open()

        manual.completeOpen()
        manual.completeOpen()
        settle(0.05)

        XCTAssertEqual(delegate.calls, [.opened])
        XCTAssertEqual(manual.closeCalls, 0)
        XCTAssertTrue(queue.isOpen)
    }

    func testClosingWhileOpeningRunsTheIdleWorkWaitingOnTheQueue() {
        let manual = ManualByteStream()
        let queue = SerialRequestQueue(stream: manual)
        queue.open()
        queue.send(exchange(1, "1"))
        var ran = false
        queue.whenIdle { ran = true }
        settle(0.05)
        XCTAssertFalse(ran)

        queue.close()

        waitUntil { ran }
    }

    func testACloseThatOvertakesASlowOpenOnAnotherThreadLeavesTheQueueClosedAndUsable() {
        let slow = LateOpeningStream()
        let queue = SerialRequestQueue(stream: slow)
        let delegate = TransportSpy()
        queue.delegate = delegate
        let opened = expectation(description: "open returned")
        DispatchQueue.global().async {
            queue.open()
            opened.fulfill()
        }
        XCTAssertTrue(slow.waitUntilOpenIsWaiting())

        queue.close()
        XCTAssertEqual(delegate.calls, [.closed(.requested)])

        slow.finishOpening()
        wait(for: [opened], timeout: 10)

        // The stream opened after all: the queue closed it again and did not report it.
        XCTAssertFalse(slow.isOpen)
        XCTAssertFalse(queue.isOpen)
        settle(0.05)
        XCTAssertEqual(delegate.calls, [.closed(.requested)])

        slow.finishOpening()
        queue.open()
        XCTAssertTrue(queue.isOpen)
        XCTAssertTrue(slow.isOpen)
        XCTAssertEqual(delegate.calls, [.closed(.requested), .opened])
    }

    func testOpeningAndClosingFromTwoThreadsNeverLeavesTheQueueStuck() {
        let group = DispatchGroup()
        let delivery = DispatchQueue(label: "SerialRequestQueueTests.twoThreads")
        for iteration in 0..<300 {
            let stream = SimulatedByteStream(device: SilentDevice(), replyLatency: 0)
            let queue = SerialRequestQueue(
                stream: stream,
                configuration: SerialRequestQueue.Configuration(deliveryQueue: delivery)
            )
            let delegate = TransportSpy()
            queue.delegate = delegate
            let start = DispatchSemaphore(value: 0)
            DispatchQueue.global().async(group: group) {
                start.wait()
                queue.open()
            }
            DispatchQueue.global().async(group: group) {
                start.wait()
                queue.close()
            }
            start.signal()
            start.signal()
            XCTAssertEqual(group.wait(timeout: .now() + 10), .success)

            queue.close()
            XCTAssertFalse(queue.isOpen, "iteration \(iteration)")
            XCTAssertFalse(stream.isOpen, "iteration \(iteration)")
            queue.open()
            XCTAssertTrue(queue.isOpen, "iteration \(iteration)")
            queue.close()
        }
    }

    // MARK: Order of open and close for the delegate

    func testAnOpenWaitingForTheDeliveryQueueIsDroppedWhenACloseWasDeliveredAheadOfIt() {
        let manual = ManualByteStream()
        manual.closeReport = .requested
        let delivery = DispatchQueue(label: "SerialRequestQueueTests.openDelivery")
        let queue = SerialRequestQueue(
            stream: manual,
            configuration: SerialRequestQueue.Configuration(deliveryQueue: delivery)
        )
        let delegate = TransportSpy()
        queue.delegate = delegate
        queue.open()
        let busy = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        delivery.async {
            busy.signal()
            _ = proceed.wait(timeout: .now() + 10)
            // On the delivery queue, so the close is delivered at once, ahead of the open below.
            queue.close()
        }
        XCTAssertEqual(busy.wait(timeout: .now() + 10), .success)

        manual.completeOpen()
        proceed.signal()
        delivery.sync {}

        XCTAssertEqual(delegate.calls, [.closed(.requested)])
        XCTAssertFalse(queue.isOpen)
    }

    func testAnOpenWaitingForTheDeliveryQueueIsDroppedWhenTheQueueWasClosedAndOpenedAgain() {
        let manual = ManualByteStream()
        manual.closeReport = .requested
        let delivery = DispatchQueue(label: "SerialRequestQueueTests.openDelivery")
        let queue = SerialRequestQueue(
            stream: manual,
            configuration: SerialRequestQueue.Configuration(deliveryQueue: delivery)
        )
        let delegate = TransportSpy()
        queue.delegate = delegate
        queue.open()
        let busy = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        delivery.async {
            busy.signal()
            _ = proceed.wait(timeout: .now() + 10)
            queue.close()
            queue.open()
            manual.completeOpen()
        }
        XCTAssertEqual(busy.wait(timeout: .now() + 10), .success)

        manual.completeOpen()
        proceed.signal()
        delivery.sync {}

        // The first open is over: the delegate hears of the second one only.
        XCTAssertEqual(delegate.calls, [.closed(.requested), .opened])
        XCTAssertTrue(queue.isOpen)
    }

    func testAnOpenIsStillDeliveredWhenNothingClosedTheQueueMeanwhile() {
        let manual = ManualByteStream()
        let delivery = DispatchQueue(label: "SerialRequestQueueTests.openDelivery")
        let queue = SerialRequestQueue(
            stream: manual,
            configuration: SerialRequestQueue.Configuration(deliveryQueue: delivery)
        )
        let delegate = TransportSpy()
        queue.delegate = delegate
        queue.open()

        manual.completeOpen()
        delivery.sync {}

        XCTAssertEqual(delegate.calls, [.opened])
    }

    // MARK: Delegates

    func testADelegateNeedNotImplementDidEncounterAndOneThatDoesStillHearsIt() {
        let rig = Rig()
        let minimal = MinimalDelegate()
        let asProtocol: SerialTransportDelegate = minimal

        asProtocol.transport(rig.queue, didEncounter: .readFailed(code: 5))

        let spy: SerialTransportDelegate = rig.delegate
        spy.transport(rig.queue, didEncounter: .readFailed(code: 5))
        XCTAssertEqual(rig.delegate.calls, [.encountered(.readFailed(code: 5))])
    }

    // MARK: Sending on a closed queue

    func testSendingOnAClosedQueueWritesAndDeliversNothing() {
        let rig = Rig(script: [.silence(), .silence()])

        rig.queue.send(exchange(1, "1", timeout: 0.05))
        rig.queue.sendWithoutReply(ascii("w"))
        settle(0.2)

        XCTAssertEqual(rig.stream.writes, [])
        XCTAssertEqual(rig.delegate.calls, [])
        XCTAssertEqual(rig.observer.tags, [])

        rig.queue.open()
        settle(0.2)

        // Opening does not revive what was sent while it was closed.
        XCTAssertEqual(rig.stream.writes, [])
        XCTAssertEqual(rig.delegate.calls, [.opened])
    }

    func testSendingAfterACloseWritesAndDeliversNothing() {
        let rig = Rig(script: [.silence()])
        rig.queue.open()
        rig.queue.close()

        rig.queue.send(exchange(1, "1", timeout: 0.05))
        rig.queue.sendWithoutReply(ascii("w"))
        settle(0.2)

        XCTAssertEqual(rig.stream.writes, [])
        XCTAssertEqual(rig.delegate.calls, [.opened, .closed(.requested)])
        XCTAssertEqual(rig.observer.tags, [.opened, .closed(.requested)])
    }

    // MARK: whenIdle

    func testWhenIdleRunsAtOnceOnTheDeliveryQueueWhenNothingIsQueued() {
        let rig = Rig()
        rig.queue.open()
        var ranOnMain: Bool?

        rig.queue.whenIdle { ranOnMain = Thread.isMainThread }

        waitUntil { ranOnMain != nil }
        XCTAssertEqual(ranOnMain, true)
    }

    func testWhenIdleWaitsUntilTheQueueHasDrained() {
        let rig = Rig(script: [.silence(), .silence()])
        rig.queue.open()
        var order: [String] = []
        rig.delegate.onCall = { call in
            if case .answered = call {
                order.append("answered")
            }
        }

        rig.queue.send(exchange(1, "1"))
        rig.queue.sendWithoutReply(ascii("w"))
        rig.queue.whenIdle { order.append("idle") }
        waitUntil { rig.stream.writes.count == 1 }
        settle(0.1)
        XCTAssertEqual(order, [])

        rig.stream.receive(ascii("A"))
        waitUntil { order.count == 2 }
        waitUntil { rig.stream.writes.count == 2 }

        XCTAssertEqual(order, ["answered", "idle"])
        XCTAssertEqual(rig.writtenFrames, [ascii("1"), ascii("w")])
    }

    func testWhenIdleRunsWhileACallerKeepsPollingFromInsideEachAnswer() {
        let rounds = 6
        let step = ReplayStep.reply(with: [ReplayChunk(ascii("A"), at: 0.03)])
        let rig = Rig(script: Array(repeating: step, count: rounds))
        rig.queue.open()
        var answered = 0
        var answeredWhenIdle: Int?
        rig.delegate.onCall = { [weak rig] call in
            if case .answered = call {
                answered += 1
                if answered < rounds {
                    rig?.queue.send(self.exchange(answered + 1, "q"))
                }
            }
        }

        rig.queue.send(exchange(1, "q"))
        rig.queue.whenIdle { answeredWhenIdle = answered }
        waitUntil { answered == rounds }

        // Each round leaves a moment with nothing queued and nothing on the wire: the first one will do.
        XCTAssertEqual(answeredWhenIdle, 1)
    }

    func testWhenIdleRunsOnAQueueThatWasNeverOpened() {
        let rig = Rig()
        var ran = false

        rig.queue.whenIdle { ran = true }

        waitUntil { ran }
    }

    func testWhenIdleRunsWhenTheQueueIsClosedWhileItWaits() {
        let rig = Rig(script: [.silence()])
        rig.queue.open()
        var order: [String] = []
        rig.delegate.onCall = { call in
            if case .closed = call {
                order.append("closed")
            }
        }
        rig.queue.send(exchange(1, "1"))
        rig.queue.whenIdle { order.append("idle") }
        waitUntil { rig.observer.has(.sent(1)) }
        settle(0.05)
        XCTAssertEqual(order, [])

        rig.queue.close()
        waitUntil { order.count == 2 }

        XCTAssertEqual(order, ["closed", "idle"])
    }

    func testWhenIdleRunsAfterATimeoutThatEmptiesTheQueue() {
        let rig = Rig(script: [.silence()], gap: 0.5)
        rig.queue.open()
        var ran = false
        rig.queue.send(exchange(1, "1", timeout: 0.05))
        rig.queue.whenIdle { ran = true }

        waitUntil { ran }

        XCTAssertTrue(rig.observer.has(.timedOut(1)))
        XCTAssertFalse(rig.observer.has(.sent(2)))
    }

    // MARK: Observers

    func testObserversAreHeldWeakly() {
        let rig = Rig(script: [.silence()])
        weak var released: ObserverSpy?
        do {
            let temporary = ObserverSpy()
            released = temporary
            rig.queue.addObserver(temporary)
        }

        XCTAssertNil(released)
        rig.queue.open()
        rig.queue.send(exchange(1, "1", timeout: 0.05))
        waitUntil { rig.observer.has(.timedOut(1)) }
    }

    func testARemovedObserverStopsReceivingAndOthersDoNot() {
        let rig = Rig(script: [.silence()])
        let removed = ObserverSpy()
        rig.queue.addObserver(removed)
        rig.queue.open()
        XCTAssertEqual(removed.tags, [.opened])

        rig.queue.removeObserver(removed)
        rig.queue.send(exchange(1, "1", timeout: 0.05))
        waitUntil { rig.observer.has(.timedOut(1)) }

        XCTAssertEqual(removed.tags, [.opened])
        XCTAssertEqual(rig.observer.tagsWithoutRaw, [.opened, .sent(1), .timedOut(1)])
    }

    func testEveryObserverReceivesEveryEventInTheSameOrder() {
        let rig = Rig(script: [.reply(with: [ReplayChunk(ascii("A"), at: 0.02)])])
        let second = ObserverSpy()
        rig.queue.addObserver(second)
        rig.queue.open()

        rig.queue.send(exchange(1, "1"))
        // `second` is told after the rig's observer, so once it has the answer both have everything.
        waitUntil { second.has(.answered(1)) }

        XCTAssertEqual(second.tags, rig.observer.tags)
        XCTAssertEqual(second.events, rig.observer.events)
    }

    func testAddingAnObserverTwiceDeliversEachEventOnce() {
        let rig = Rig()
        rig.queue.addObserver(rig.observer)

        rig.queue.open()

        XCTAssertEqual(rig.observer.tags, [.opened])
    }

    func testObserversAreCalledOffTheCallersThreadForWhatTheStreamDelivers() {
        let rig = Rig(script: [.silence()])
        rig.queue.open()
        rig.queue.send(exchange(1, "1"))
        waitUntil { rig.observer.has(.sent(1)) }

        rig.stream.receive(ascii("A"))
        waitUntil { rig.observer.has(.answered(1)) }

        XCTAssertEqual(rig.observer.tags, [.opened, .sent(1), .raw, .answered(1)])
        XCTAssertEqual(rig.observer.publishedOnMainThread.dropFirst(), [false, false, false])
    }

    // MARK: A shared queue

    func testTheStreamAndTheQueueCanShareOneDispatchQueue() {
        let shared = DispatchQueue(label: "SerialRequestQueueTests.shared")
        let rig = Rig(
            script: [.reply(with: [ReplayChunk(ascii("OK"), at: 0.05)]), .silence()],
            sharedQueue: shared
        )
        rig.queue.open()

        rig.queue.send(exchange(1, "1", reply: .exactly(2)))
        rig.queue.send(exchange(2, "2", timeout: 0.1))
        waitUntil { rig.delegate.calls.count == 3 }

        XCTAssertEqual(rig.delegate.calls, [.opened, .answered(1, ascii("OK")), .timedOut(2)])
        XCTAssertTrue(rig.delegate.records.allSatisfy { $0.onMainThread })
        XCTAssertTrue(rig.queue.isOpen)

        rig.queue.close()
        XCTAssertEqual(rig.delegate.calls.last, .closed(.requested))
        XCTAssertFalse(rig.queue.isOpen)
    }
}
