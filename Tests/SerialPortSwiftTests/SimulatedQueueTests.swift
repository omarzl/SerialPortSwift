//
//  SimulatedQueueTests.swift
//  SerialPortSwiftTests
//
//  A `SimulatedByteStream` over a small test device, under a real `SerialRequestQueue`: the
//  simulator and the queue tested together.
//

import Foundation
import SerialPortSwift
import SerialPortSwiftSimulation
import XCTest

// MARK: - Test doubles

/// Records what a queue tells its delegate, with the thread of each call.
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
        let onMainThread: Bool
    }

    private let lock = NSLock()
    private var recorded: [Record] = []
    private var waiters: [(count: Int, expectation: XCTestExpectation)] = []
    private var hook: ((Call) -> Void)?

    /// Runs on the thread of each call, after it is recorded and with no lock held.
    var onCall: ((Call) -> Void)? {
        get {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.hook
        }
        set {
            self.lock.lock()
            self.hook = newValue
            self.lock.unlock()
        }
    }

    var records: [Record] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.recorded
    }

    var calls: [Call] {
        return self.records.map { $0.call }
    }

    /// Fulfilled once the delegate has been called `count` times in total.
    func expectCalls(_ count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "\(count) delegate calls")
        self.lock.lock()
        let alreadyThere = self.recorded.count >= count
        if !alreadyThere {
            self.waiters.append((count: count, expectation: expectation))
        }
        self.lock.unlock()
        if alreadyThere {
            expectation.fulfill()
        }
        return expectation
    }

    private func add(_ call: Call) {
        self.lock.lock()
        self.recorded.append(Record(call: call, onMainThread: Thread.isMainThread))
        let total = self.recorded.count
        let ready = self.waiters.filter { $0.count <= total }.map { $0.expectation }
        self.waiters = self.waiters.filter { $0.count > total }
        let callback = self.hook
        self.lock.unlock()
        callback?(call)
        ready.forEach { $0.fulfill() }
    }

    func transportDidOpen(_ transport: SerialTransport) {
        self.add(.opened)
    }

    func transportDidClose(_ transport: SerialTransport, reason: SerialCloseReason) {
        self.add(.closed(reason))
    }

    func transport(_ transport: SerialTransport, didAnswer exchange: SerialExchange, with reply: Data) {
        self.add(.answered(exchange.id.number, reply))
    }

    func transport(_ transport: SerialTransport, didTimeOut exchange: SerialExchange) {
        self.add(.timedOut(exchange.id.number))
    }

    func transport(_ transport: SerialTransport, didEncounter error: SerialStreamError) {
        self.add(.encountered(error))
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

    var events: [SerialQueueEvent] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.recorded
    }

    var tags: [Tag] {
        return self.events.map { Tag($0.kind) }
    }

    var tagsWithoutRaw: [Tag] {
        return self.tags.filter { $0 != .raw }
    }

    /// The chunks the stream delivered, one `.raw` event each, as the queue saw them.
    var rawChunks: [Data] {
        return self.events.filter { Tag($0.kind) == .raw }.map { $0.bytes ?? Data() }
    }

    func has(_ tag: Tag) -> Bool {
        return self.tags.contains(tag)
    }

    func firstEvent(_ tag: Tag) -> SerialQueueEvent? {
        return self.events.first { Tag($0.kind) == tag }
    }

    func bytes(of tag: Tag) -> Data? {
        return self.firstEvent(tag)?.bytes
    }

    /// The round trip published with the answer to exchange `number`.
    func roundTrip(ofExchange number: Int) -> TimeInterval? {
        guard let event = self.firstEvent(.answered(number)), case .answered(_, let roundTrip) = event.kind else {
            return nil
        }
        return roundTrip
    }

    func requestQueue(_ queue: SerialRequestQueue, didLog event: SerialQueueEvent) {
        self.lock.lock()
        self.recorded.append(event)
        self.lock.unlock()
    }
}

/// A device that answers from a function and remembers every frame it was asked about.
private final class TestDevice: SerialDeviceSimulator {
    private let lock = NSLock()
    private let responder: (Data) -> Data?
    private var recorded: [Data] = []
    private var waiters: [(count: Int, expectation: XCTestExpectation)] = []

    init(_ responder: @escaping (Data) -> Data?) {
        self.responder = responder
    }

    var frames: [Data] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.recorded
    }

    /// Fulfilled once the device has been asked about `count` frames in total.
    func expectFrames(_ count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "\(count) frames")
        self.lock.lock()
        let alreadyThere = self.recorded.count >= count
        if !alreadyThere {
            self.waiters.append((count: count, expectation: expectation))
        }
        self.lock.unlock()
        if alreadyThere {
            expectation.fulfill()
        }
        return expectation
    }

    func reply(to frame: Data) -> Data? {
        self.lock.lock()
        self.recorded.append(frame)
        let total = self.recorded.count
        let ready = self.waiters.filter { $0.count <= total }.map { $0.expectation }
        self.waiters = self.waiters.filter { $0.count > total }
        self.lock.unlock()
        ready.forEach { $0.fulfill() }
        return self.responder(frame)
    }
}

/// A device that is still composing its reply until the test lets it finish.
private final class SlowDevice: SerialDeviceSimulator {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func reply(to frame: Data) -> Data? {
        self.entered.signal()
        _ = self.release.wait(timeout: .now() + 10)
        return Data("LATE".utf8)
    }
}

/// A simulated stream, the queue over it, and what listens to the queue.
private final class Stack {
    let stream: SimulatedByteStream
    let queue: SerialRequestQueue
    let delegate = TransportSpy()
    let observer = ObserverSpy()

    init(
        device: SerialDeviceSimulator,
        matcher: ReplyMatcher = TailScanMatcher(),
        latency: TimeInterval = 0.01,
        defaultTimeout: TimeInterval = 5,
        gap: TimeInterval = 0.1
    ) {
        self.stream = SimulatedByteStream(device: device, replyLatency: latency)
        self.queue = SerialRequestQueue(
            stream: self.stream,
            matcher: matcher,
            configuration: SerialRequestQueue.Configuration(
                defaultTimeout: defaultTimeout,
                postTimeoutGap: gap
            )
        )
        self.queue.delegate = self.delegate
        self.queue.addObserver(self.observer)
    }

    func shutDown() {
        self.queue.close()
    }
}

private func ascii(_ string: String) -> Data {
    return Data(string.utf8)
}

private func exchange(
    _ number: Int,
    _ frame: Data,
    reply: ReplyShape = .exactly(1),
    timeout: TimeInterval? = nil
) -> SerialExchange {
    return SerialExchange(id: SerialExchangeID(number: number), frame: frame, reply: reply, timeout: timeout)
}

private func exchange(
    _ number: Int,
    _ frame: String,
    reply: ReplyShape = .exactly(1),
    timeout: TimeInterval? = nil
) -> SerialExchange {
    return exchange(number, ascii(frame), reply: reply, timeout: timeout)
}

// MARK: - Tests

final class SimulatedQueueTests: XCTestCase {
    private var stacks: [Stack] = []

    override func tearDown() {
        self.stacks.forEach { $0.shutDown() }
        self.stacks = []
        super.tearDown()
    }

    // MARK: Helpers

    private func makeStack(
        device: SerialDeviceSimulator,
        matcher: ReplyMatcher = TailScanMatcher(),
        latency: TimeInterval = 0.01,
        defaultTimeout: TimeInterval = 5,
        gap: TimeInterval = 0.1
    ) -> Stack {
        let stack = Stack(
            device: device,
            matcher: matcher,
            latency: latency,
            defaultTimeout: defaultTimeout,
            gap: gap
        )
        self.stacks.append(stack)
        return stack
    }

    /// A device that answers `PING` with `OK` and the frame `A` with `a`, `B` with `b`, and nothing else.
    private func makeTableDevice() -> TestDevice {
        return TestDevice { frame in
            switch frame {
            case ascii("PING"):
                return ascii("OK")
            case ascii("A"):
                return ascii("a")
            case ascii("B"):
                return ascii("b")
            default:
                return nil
            }
        }
    }

    /// Lets the main queue run for `seconds`: a block scheduled on it ends the wait, so anything that
    /// should not happen has its chance.
    private func settle(_ seconds: TimeInterval) {
        let done = XCTestExpectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            done.fulfill()
        }
        self.wait(for: [done], timeout: seconds + 10)
    }

    // MARK: Exchanges

    func testAnExchangeIsAnsweredByTheSimulatedDevice() {
        let device = self.makeTableDevice()
        let stack = self.makeStack(device: device, latency: 0.05)
        stack.queue.open()
        XCTAssertEqual(stack.delegate.calls, [.opened])
        let answered = stack.delegate.expectCalls(2)

        stack.queue.send(exchange(1, "PING", reply: .exactly(2)))
        self.wait(for: [answered], timeout: 15)

        XCTAssertEqual(stack.delegate.calls, [.opened, .answered(1, ascii("OK"))])
        XCTAssertEqual(stack.delegate.records.map { $0.onMainThread }, [true, true])
        XCTAssertEqual(device.frames, [ascii("PING")])
        XCTAssertEqual(stack.observer.tagsWithoutRaw, [.opened, .sent(1), .answered(1)])
        XCTAssertEqual(stack.observer.bytes(of: .sent(1)), ascii("PING"))
        XCTAssertEqual(stack.observer.bytes(of: .answered(1)), ascii("OK"))
        XCTAssertEqual(stack.observer.rawChunks, [ascii("OK")])
        guard let roundTrip = stack.observer.roundTrip(ofExchange: 1) else {
            return XCTFail("No answer published: \(stack.observer.tags)")
        }
        // The stream times its latency from the write, a moment before the queue notes the write.
        XCTAssertGreaterThanOrEqual(roundTrip, 0.05 - 0.02)
        XCTAssertLessThan(roundTrip, 0.05 + 2)
    }

    func testAnAnythingExchangeTakesTheFirstByteAndDropsTheRest() {
        let stack = self.makeStack(device: self.makeTableDevice())
        stack.queue.open()
        let answered = stack.delegate.expectCalls(2)

        stack.queue.send(exchange(1, "PING", reply: .anything))
        self.wait(for: [answered], timeout: 15)
        self.settle(0.1)

        XCTAssertEqual(stack.delegate.calls, [.opened, .answered(1, ascii("O"))])
        XCTAssertEqual(stack.observer.tagsWithoutRaw, [.opened, .sent(1), .answered(1), .unsolicited])
        XCTAssertEqual(stack.observer.bytes(of: .unsolicited), ascii("K"))
    }

    func testWritesWithoutAReplyReachTheDeviceInOrderWithTheExchanges() {
        let device = self.makeTableDevice()
        let stack = self.makeStack(device: device)
        stack.queue.open()
        let answered = stack.delegate.expectCalls(2)
        let allSeen = device.expectFrames(3)

        stack.queue.sendWithoutReply(ascii("X"))
        stack.queue.send(exchange(1, "A"))
        stack.queue.sendWithoutReply(ascii("Y"))
        self.wait(for: [answered, allSeen], timeout: 15)

        XCTAssertEqual(device.frames, [ascii("X"), ascii("A"), ascii("Y")])
        XCTAssertEqual(stack.delegate.calls, [.opened, .answered(1, ascii("a"))])
        XCTAssertEqual(stack.observer.tagsWithoutRaw, [.opened, .sent(nil), .sent(1), .answered(1), .sent(nil)])
    }

    // MARK: Faults

    func testADroppedReplyTimesTheExchangeOutAndTheNextOneIsAnswered() {
        let device = self.makeTableDevice()
        let stack = self.makeStack(device: device)
        stack.queue.open()
        stack.stream.dropNextReply()
        XCTAssertTrue(stack.stream.isDropArmed)
        let finished = stack.delegate.expectCalls(3)

        stack.queue.send(exchange(1, "PING", reply: .exactly(2), timeout: 0.2))
        stack.queue.send(exchange(2, "PING", reply: .exactly(2), timeout: 5))
        self.wait(for: [finished], timeout: 15)

        // The device was asked both times; the stream swallowed the first answer only.
        XCTAssertEqual(device.frames, [ascii("PING"), ascii("PING")])
        XCTAssertFalse(stack.stream.isDropArmed)
        XCTAssertEqual(stack.delegate.calls, [.opened, .timedOut(1), .answered(2, ascii("OK"))])
        XCTAssertEqual(stack.delegate.records.map { $0.onMainThread }, [true, true, true])
        XCTAssertEqual(stack.observer.tagsWithoutRaw, [.opened, .sent(1), .timedOut(1), .sent(2), .answered(2)])
        XCTAssertEqual(stack.observer.bytes(of: .timedOut(1)), ascii("PING"))
        XCTAssertEqual(stack.observer.rawChunks, [ascii("OK")])
        guard let timedOut = stack.observer.firstEvent(.timedOut(1)), let sent = stack.observer.firstEvent(.sent(1)) else {
            return XCTFail("Missing events: \(stack.observer.tags)")
        }
        let waited = timedOut.date.timeIntervalSince(sent.date)
        XCTAssertGreaterThanOrEqual(waited, 0.2 - 0.01)
        XCTAssertLessThan(waited, 0.2 + 2)
    }

    func testADroppedReplySkipsWritesTheDeviceDoesNotAnswer() {
        let device = self.makeTableDevice()
        let stack = self.makeStack(device: device)
        stack.queue.open()
        stack.stream.dropNextReply()
        let finished = stack.delegate.expectCalls(2)

        // The command has no reply to drop, so it does not use the fault up; the exchange's reply does.
        stack.queue.sendWithoutReply(ascii("CMD"))
        stack.queue.send(exchange(1, "A", timeout: 0.2))
        self.wait(for: [finished], timeout: 15)

        XCTAssertEqual(stack.delegate.calls, [.opened, .timedOut(1)])
        XCTAssertEqual(device.frames, [ascii("CMD"), ascii("A")])
        XCTAssertFalse(stack.stream.isDropArmed)
        XCTAssertEqual(stack.observer.rawChunks, [])
    }

    func testFillerBytesInFrontOfEveryReplyAreSetAsideButStayInTheRawLog() {
        let device = self.makeTableDevice()
        let matcher = TailScanMatcher(fillerBytes: [0xFF], requiresASCII: true, lengthUnit: .characters)
        let stack = self.makeStack(device: device, matcher: matcher)
        stack.stream.fillerByteCount = 2
        stack.queue.open()
        let finished = stack.delegate.expectCalls(3)

        stack.queue.send(exchange(1, "A", reply: .exactly(1)))
        stack.queue.send(exchange(2, "B", reply: .exactly(1)))
        self.wait(for: [finished], timeout: 15)

        XCTAssertEqual(stack.delegate.calls, [.opened, .answered(1, ascii("a")), .answered(2, ascii("b"))])
        XCTAssertEqual(stack.observer.bytes(of: .answered(1)), ascii("a"))
        XCTAssertEqual(stack.observer.bytes(of: .answered(2)), ascii("b"))
        XCTAssertEqual(
            stack.observer.rawChunks,
            [Data([0xFF, 0xFF, 0x61]), Data([0xFF, 0xFF, 0x62])]
        )
        XCTAssertFalse(stack.observer.has(.unreadable(1)))
        XCTAssertFalse(stack.observer.has(.unreadable(2)))
        XCTAssertFalse(stack.observer.has(.unsolicited))
    }

    // MARK: Removal

    func testRemovalOnTheMainThreadClosesTheQueueAsRemovedBeforeItReturnsAndNothingIsAnsweredAfterwards() {
        let device = self.makeTableDevice()
        // The reply is on its way (0.2 s) when the device is unplugged; the exchange would time out at 0.5 s.
        let stack = self.makeStack(device: device, latency: 0.2)
        stack.queue.open()
        let asked = device.expectFrames(1)
        stack.queue.send(exchange(1, "PING", reply: .exactly(2), timeout: 0.5))
        self.wait(for: [asked], timeout: 15)

        stack.stream.simulateRemoval()

        XCTAssertEqual(stack.delegate.calls, [.opened, .closed(.removed)])
        XCTAssertEqual(stack.delegate.records.map { $0.onMainThread }, [true, true])
        XCTAssertFalse(stack.queue.isOpen)
        XCTAssertFalse(stack.stream.isOpen)

        // Longer than the reply's latency and than the exchange's timeout: nothing more happens.
        self.settle(0.8)

        XCTAssertEqual(stack.delegate.calls, [.opened, .closed(.removed)])
        XCTAssertEqual(stack.observer.tagsWithoutRaw, [.opened, .sent(1), .closed(.removed)])
        XCTAssertEqual(stack.observer.rawChunks, [])
    }

    func testRemovalFromAnotherThreadIsDeliveredOnTheMainThread() {
        let stack = self.makeStack(device: self.makeTableDevice())
        stack.queue.open()
        let closed = stack.delegate.expectCalls(2)

        DispatchQueue.global().async {
            stack.stream.simulateRemoval()
        }
        self.wait(for: [closed], timeout: 15)

        XCTAssertEqual(stack.delegate.calls, [.opened, .closed(.removed)])
        XCTAssertEqual(stack.delegate.records.map { $0.onMainThread }, [true, true])
        XCTAssertFalse(stack.queue.isOpen)
    }

    func testAReplyTheDeviceWasStillComposingWhenItWasUnpluggedIsLost() {
        let slow = SlowDevice()
        let stack = self.makeStack(device: slow, latency: 0)
        stack.queue.open()

        stack.queue.send(exchange(1, "PING", reply: .exactly(4), timeout: 0.5))
        XCTAssertEqual(slow.entered.wait(timeout: .now() + 10), .success)
        stack.stream.simulateRemoval()
        slow.release.signal()
        self.settle(0.8)

        XCTAssertEqual(stack.delegate.calls, [.opened, .closed(.removed)])
        XCTAssertEqual(stack.observer.tagsWithoutRaw, [.opened, .sent(1), .closed(.removed)])
    }

    func testTheQueueReopensAfterARemovalAndNothingFromBeforeLeaksIn() {
        let device = self.makeTableDevice()
        // The first reply would arrive 0.3 s after its write: well after the second exchange is written.
        let stack = self.makeStack(device: device, latency: 0.3)
        stack.queue.open()
        let asked = device.expectFrames(1)
        stack.queue.send(exchange(1, "A", timeout: 5))
        self.wait(for: [asked], timeout: 15)

        stack.stream.simulateRemoval()
        XCTAssertEqual(stack.delegate.calls, [.opened, .closed(.removed)])
        // A queue that is closed takes nothing.
        stack.queue.send(exchange(9, "A", timeout: 0.1))

        stack.queue.open()
        XCTAssertEqual(stack.delegate.calls, [.opened, .closed(.removed), .opened])
        XCTAssertTrue(stack.queue.isOpen)
        XCTAssertTrue(stack.stream.isOpen)
        let answered = stack.delegate.expectCalls(4)
        stack.queue.send(exchange(2, "B", timeout: 5))
        self.wait(for: [answered], timeout: 15)
        // Past the moment the first exchange's reply would have come.
        self.settle(0.5)

        XCTAssertEqual(
            stack.delegate.calls,
            [.opened, .closed(.removed), .opened, .answered(2, ascii("b"))]
        )
        XCTAssertEqual(device.frames, [ascii("A"), ascii("B")])
        XCTAssertEqual(stack.observer.rawChunks, [ascii("b")])
        XCTAssertFalse(stack.observer.has(.timedOut(1)))
        XCTAssertFalse(stack.observer.has(.sent(9)))
    }

    // MARK: Polling

    func testAPollingLoopOfAHundredExchangesIsAnsweredAndIdleWorkRunsBetweenTwoPolls() {
        let rounds = 100
        let stagedAfter = 50
        // Answers a poll `[0x50, n]` with `[0x52, n]`.
        let device = TestDevice { frame in
            return frame.count == 2 ? Data([0x52, frame[frame.startIndex + 1]]) : nil
        }
        let stack = self.makeStack(device: device, latency: 0.001)
        let allAnswered = stack.delegate.expectCalls(rounds + 1)

        // Everything below runs on the main queue, where the delegate is called.
        var answeredNumbers: [Int] = []
        var answeredWhenIdleRan: [Int] = []
        var idleWorkOnMain: [Bool] = []
        stack.delegate.onCall = { [weak stack] call in
            guard case .answered(let number, let reply) = call else {
                return
            }
            if reply != Data([0x52, UInt8(number)]) {
                XCTFail("Exchange \(number) was answered with \(Array(reply))")
            }
            answeredNumbers.append(number)
            if number == stagedAfter {
                // Staged between two polls: nothing is queued until the next one is sent below.
                stack?.queue.whenIdle {
                    answeredWhenIdleRan.append(answeredNumbers.count)
                    idleWorkOnMain.append(Thread.isMainThread)
                }
            }
            if number < rounds {
                let next = number + 1
                stack?.queue.send(exchange(next, Data([0x50, UInt8(next)]), reply: .exactly(2), timeout: 10))
            }
        }
        stack.queue.open()

        stack.queue.send(exchange(1, Data([0x50, 0x01]), reply: .exactly(2), timeout: 10))
        self.wait(for: [allAnswered], timeout: 60)
        self.settle(0.1)

        XCTAssertEqual(answeredNumbers, Array(1...rounds))
        XCTAssertEqual(stack.delegate.calls.count, rounds + 1)
        XCTAssertEqual(stack.delegate.calls.first, .opened)
        XCTAssertEqual(device.frames.count, rounds)
        XCTAssertFalse(stack.observer.has(.timedOut(1)))
        XCTAssertFalse(stack.observer.has(.late))
        XCTAssertFalse(stack.observer.has(.unsolicited))
        // The idle work ran once, on the main queue, after the poll it was staged behind and before
        // the next poll's answer: it was not starved until the loop ended.
        XCTAssertEqual(answeredWhenIdleRan, [stagedAfter])
        XCTAssertEqual(idleWorkOnMain, [true])
    }
}
