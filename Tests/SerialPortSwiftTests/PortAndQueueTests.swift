//
//  PortAndQueueTests.swift
//  SerialPortSwiftTests
//
//  A real `PosixSerialPort` on a `PseudoTerminal`, under a real `SerialRequestQueue`: the pieces
//  tested together. The test plays the device on the pseudo-terminal, on a queue of its own.
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
    private var waiters: [(tag: Tag, times: Int, expectation: XCTestExpectation)] = []
    private var hook: ((SerialQueueEvent) -> Void)?

    /// Runs on the queue's serial queue, for each event, after it is recorded and with no lock held.
    var onEvent: ((SerialQueueEvent) -> Void)? {
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

    /// Everything the stream delivered, chunk after chunk, as the queue saw it before deciding what it was.
    var rawBytes: Data {
        var all = Data()
        for event in self.events where Tag(event.kind) == .raw {
            all.append(event.bytes ?? Data())
        }
        return all
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

    /// The time between the first events tagged `start` and `end`, by the wall clock.
    func elapsed(from start: Tag, to end: Tag, file: StaticString = #file, line: UInt = #line) -> TimeInterval {
        guard let first = self.firstEvent(start), let second = self.firstEvent(end) else {
            XCTFail("Missing \(start) or \(end) in \(self.tags)", file: file, line: line)
            return 0
        }
        return second.date.timeIntervalSince(first.date)
    }

    /// Fulfilled once `times` events tagged `tag` have been published.
    func expect(_ tag: Tag, times: Int = 1) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "\(tag) x\(times)")
        self.lock.lock()
        let alreadyThere = self.recorded.filter { Tag($0.kind) == tag }.count >= times
        if !alreadyThere {
            self.waiters.append((tag: tag, times: times, expectation: expectation))
        }
        self.lock.unlock()
        if alreadyThere {
            expectation.fulfill()
        }
        return expectation
    }

    func requestQueue(_ queue: SerialRequestQueue, didLog event: SerialQueueEvent) {
        let tag = Tag(event.kind)
        self.lock.lock()
        self.recorded.append(event)
        let total = self.recorded.filter { Tag($0.kind) == tag }.count
        let ready = self.waiters.filter { $0.tag == tag && $0.times <= total }.map { $0.expectation }
        self.waiters = self.waiters.filter { !($0.tag == tag && $0.times <= total) }
        let callback = self.hook
        self.lock.unlock()
        callback?(event)
        ready.forEach { $0.fulfill() }
    }
}

/// The device on the far end of a pseudo-terminal: it reads what the port wrote and answers, on a
/// queue of its own, so the main thread stays free to run the delegate while the test waits.
private final class Device {
    let terminal: PseudoTerminal
    private let queue = DispatchQueue(label: "PortAndQueueTests.device")
    private let lock = NSLock()
    private var noted: [String] = []

    init(_ terminal: PseudoTerminal) {
        self.terminal = terminal
    }

    /// What went wrong on the device's side, for the test to assert on from the main thread.
    var problems: [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.noted
    }

    func note(_ problem: String) {
        self.lock.lock()
        self.noted.append(problem)
        self.lock.unlock()
    }

    /// Runs `script` on the device's queue. The expectation is fulfilled when the script has finished.
    func play(_ description: String, _ script: @escaping (Device) -> Void) -> XCTestExpectation {
        let finished = XCTestExpectation(description: description)
        self.queue.async {
            script(self)
            finished.fulfill()
        }
        return finished
    }

    /// Reads exactly `expected.count` bytes and notes a problem unless they are `expected`.
    @discardableResult
    func expect(_ expected: Data, timeout: TimeInterval = 5) -> Bool {
        guard let received = self.terminal.read(count: expected.count, timeout: timeout) else {
            self.note("expected \(Array(expected)) from the port, but it did not arrive in time")
            return false
        }
        if received != expected {
            self.note("expected \(Array(expected)) from the port, got \(Array(received))")
            return false
        }
        return true
    }

    /// Notes a problem if anything at all arrives from the port within `duration`.
    @discardableResult
    func expectSilence(for duration: TimeInterval) -> Bool {
        let unexpected = self.terminal.read(timeout: duration)
        if !unexpected.isEmpty {
            self.note("expected nothing from the port, got \(Array(unexpected))")
            return false
        }
        return true
    }

    func send(_ bytes: Data) {
        do {
            try self.terminal.write(bytes)
        } catch {
            self.note("writing \(Array(bytes)) failed: \(error)")
        }
    }

    func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func hangUp() {
        self.terminal.close()
    }
}

/// A port, the queue over it, and what listens to the queue.
private final class Stack {
    let port: PosixSerialPort
    let queue: SerialRequestQueue
    let delegate = TransportSpy()
    let observer = ObserverSpy()

    init(
        path: String,
        matcher: ReplyMatcher = TailScanMatcher(),
        defaultTimeout: TimeInterval = 5,
        gap: TimeInterval = 0.1,
        sharedQueue: DispatchQueue? = nil
    ) {
        self.port = PosixSerialPort(path: path, queue: sharedQueue)
        self.queue = SerialRequestQueue(
            stream: self.port,
            matcher: matcher,
            configuration: SerialRequestQueue.Configuration(
                defaultTimeout: defaultTimeout,
                postTimeoutGap: gap
            ),
            queue: sharedQueue
        )
        self.queue.delegate = self.delegate
        self.queue.addObserver(self.observer)
    }

    func shutDown() {
        self.queue.close()
        self.port.close()
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

final class PortAndQueueTests: XCTestCase {
    private var terminals: [PseudoTerminal] = []
    private var stacks: [Stack] = []

    override func tearDown() {
        self.stacks.forEach { $0.shutDown() }
        self.stacks = []
        // Closing the device side also ends any device script still waiting for the port.
        self.terminals.forEach { $0.close() }
        self.terminals = []
        super.tearDown()
    }

    // MARK: Helpers

    private func makeTerminal() throws -> PseudoTerminal {
        let terminal = try PseudoTerminal()
        self.terminals.append(terminal)
        return terminal
    }

    private func makeStack(
        on terminal: PseudoTerminal,
        matcher: ReplyMatcher = TailScanMatcher(),
        defaultTimeout: TimeInterval = 5,
        gap: TimeInterval = 0.1,
        sharedQueue: DispatchQueue? = nil
    ) -> Stack {
        let stack = Stack(
            path: terminal.devicePath,
            matcher: matcher,
            defaultTimeout: defaultTimeout,
            gap: gap,
            sharedQueue: sharedQueue
        )
        self.stacks.append(stack)
        return stack
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

    /// The frame and the reply of the numbered exchange of the longer runs.
    private func numberedFrame(_ number: Int) -> Data {
        return ascii(String(format: "Q%02d", number))
    }

    private func numberedReply(_ number: Int) -> Data {
        return ascii(String(format: "r%02d", number))
    }

    // MARK: Opening

    func testOpeningThroughTheQueueIsReportedOnTheMainThreadBeforeOpenReturns() throws {
        let terminal = try self.makeTerminal()
        let stack = self.makeStack(on: terminal)
        XCTAssertFalse(stack.queue.isOpen)
        XCTAssertFalse(stack.port.isOpen)

        stack.queue.open()

        XCTAssertEqual(stack.delegate.calls, [.opened])
        XCTAssertEqual(stack.delegate.records.map { $0.onMainThread }, [true])
        XCTAssertTrue(stack.queue.isOpen)
        XCTAssertTrue(stack.port.isOpen)
        XCTAssertEqual(stack.queue.name, stack.port.name)
        XCTAssertEqual(stack.observer.tagsWithoutRaw, [.opened])
    }

    // MARK: Exchanges

    func testAnExchangeReachesTheDeviceByteForByteAndItsReplyIsAnsweredRaw() throws {
        let terminal = try self.makeTerminal()
        let device = Device(terminal)
        let stack = self.makeStack(on: terminal)
        stack.queue.open()
        // Bytes a line discipline would mangle if the port left it cooked: CR, LF, NUL, XON, XOFF, DEL
        // and the high half.
        let frame = Data([0x01, 0x0D, 0x0A, 0x00, 0x11, 0x13, 0x7F, 0x80, 0xFE])
        let reply = Data([0x0A, 0x0D, 0x00, 0x13, 0x81, 0xFE])
        let played = device.play("device answers") { device in
            if device.expect(frame) {
                device.send(reply)
            }
        }
        let answered = stack.delegate.expectCalls(2)

        stack.queue.send(exchange(1, frame, reply: .exactly(6), timeout: 5))
        self.wait(for: [played, answered], timeout: 15)

        XCTAssertEqual(device.problems, [])
        XCTAssertEqual(stack.delegate.calls, [.opened, .answered(1, reply)])
        XCTAssertEqual(stack.delegate.records.map { $0.onMainThread }, [true, true])
        XCTAssertEqual(stack.observer.tagsWithoutRaw, [.opened, .sent(1), .answered(1)])
        XCTAssertEqual(stack.observer.bytes(of: .sent(1)), frame)
        XCTAssertEqual(stack.observer.bytes(of: .answered(1)), reply)
        XCTAssertEqual(stack.observer.rawBytes, reply)
        guard let roundTrip = stack.observer.roundTrip(ofExchange: 1) else {
            return XCTFail("No answer published: \(stack.observer.tags)")
        }
        XCTAssertGreaterThan(roundTrip, 0)
        XCTAssertLessThan(roundTrip, 5)
    }

    func testAReplyThatArrivesInTwoWritesIsAnsweredOnceWhenItIsComplete() throws {
        let terminal = try self.makeTerminal()
        let device = Device(terminal)
        let stack = self.makeStack(on: terminal)
        stack.queue.open()
        let played = device.play("device answers in two parts") { device in
            if device.expect(ascii("Q")) {
                device.send(ascii("AB"))
                device.pause(0.05)
                device.send(ascii("CD"))
            }
        }
        let answered = stack.delegate.expectCalls(2)

        stack.queue.send(exchange(1, "Q", reply: .exactly(4)))
        self.wait(for: [played, answered], timeout: 15)
        self.settle(0.3)

        XCTAssertEqual(device.problems, [])
        XCTAssertEqual(stack.delegate.calls, [.opened, .answered(1, ascii("ABCD"))])
        XCTAssertEqual(stack.observer.bytes(of: .answered(1)), ascii("ABCD"))
        XCTAssertEqual(stack.observer.rawBytes, ascii("ABCD"))
        XCTAssertEqual(stack.observer.tagsWithoutRaw, [.opened, .sent(1), .answered(1)])
        // The round trip ends at the reply's last byte, which came after the pause.
        XCTAssertGreaterThanOrEqual(stack.observer.roundTrip(ofExchange: 1) ?? 0, 0.045)
    }

    // MARK: Timeouts

    func testASilentDeviceTimesTheExchangeOutAndTheNextExchangeStillWorks() throws {
        let terminal = try self.makeTerminal()
        let device = Device(terminal)
        let stack = self.makeStack(on: terminal, gap: 0.1)
        stack.queue.open()
        let played = device.play("device ignores the first frame") { device in
            guard device.expect(ascii("1")) else {
                return
            }
            // Silent for the first exchange; the second is written once the pause after the timeout is over.
            if device.expect(ascii("2")) {
                device.send(ascii("B"))
            }
        }
        let finished = stack.delegate.expectCalls(3)

        stack.queue.send(exchange(1, "1", timeout: 0.2))
        stack.queue.send(exchange(2, "2", timeout: 5))
        self.wait(for: [played, finished], timeout: 15)

        XCTAssertEqual(device.problems, [])
        XCTAssertEqual(stack.delegate.calls, [.opened, .timedOut(1), .answered(2, ascii("B"))])
        XCTAssertEqual(stack.delegate.records.map { $0.onMainThread }, [true, true, true])
        XCTAssertEqual(stack.observer.tagsWithoutRaw, [.opened, .sent(1), .timedOut(1), .sent(2), .answered(2)])
        XCTAssertEqual(stack.observer.bytes(of: .timedOut(1)), ascii("1"))
        let waited = stack.observer.elapsed(from: .sent(1), to: .timedOut(1))
        XCTAssertGreaterThanOrEqual(waited, 0.2 - 0.01)
        XCTAssertLessThan(waited, 0.2 + 2)
        // The second frame waited for the pause that follows a timeout.
        XCTAssertGreaterThanOrEqual(stack.observer.elapsed(from: .timedOut(1), to: .sent(2)), 0.1 - 0.01)
    }

    func testBytesThatArriveInThePauseAfterATimeoutAreNotCreditedToTheNextExchange() throws {
        let terminal = try self.makeTerminal()
        let device = Device(terminal)
        let stack = self.makeStack(on: terminal, gap: 0.6)
        // The device answers the first exchange only once the queue has given up on it, so the late
        // byte falls in the pause however slow the machine is.
        let gaveUp = DispatchSemaphore(value: 0)
        stack.observer.onEvent = { event in
            if Tag(event.kind) == .timedOut(1) {
                gaveUp.signal()
            }
        }
        stack.queue.open()
        let played = device.play("device answers late, then on time") { device in
            guard device.expect(ascii("1")) else {
                return
            }
            if gaveUp.wait(timeout: .now() + 10) != .success {
                device.note("the first exchange never timed out")
                return
            }
            device.send(ascii("L"))
            if device.expect(ascii("2")) {
                device.send(ascii("B"))
            }
        }
        let finished = stack.delegate.expectCalls(3)

        stack.queue.send(exchange(1, "1", timeout: 0.15))
        stack.queue.send(exchange(2, "2", timeout: 5))
        self.wait(for: [played, finished], timeout: 20)

        XCTAssertEqual(device.problems, [])
        XCTAssertEqual(stack.delegate.calls, [.opened, .timedOut(1), .answered(2, ascii("B"))])
        XCTAssertEqual(
            stack.observer.tagsWithoutRaw,
            [.opened, .sent(1), .timedOut(1), .late, .sent(2), .answered(2)]
        )
        XCTAssertEqual(stack.observer.bytes(of: .late), ascii("L"))
        XCTAssertEqual(stack.observer.bytes(of: .answered(2)), ascii("B"))
        XCTAssertEqual(stack.observer.rawBytes, ascii("LB"))
    }

    // MARK: Writes without a reply

    func testWritesWithoutAReplyReachTheDeviceInOrderWithTheExchanges() throws {
        let terminal = try self.makeTerminal()
        let device = Device(terminal)
        let stack = self.makeStack(on: terminal)
        stack.queue.open()
        let played = device.play("device sees the writes in order") { device in
            // The first command and the exchange go out back to back.
            guard device.expect(ascii("C1Q")) else {
                return
            }
            // The second command waits for the exchange's reply.
            guard device.expectSilence(for: 0.2) else {
                return
            }
            device.send(ascii("R"))
            device.expect(ascii("C2"))
        }
        let answered = stack.delegate.expectCalls(2)
        let secondCommandSent = stack.observer.expect(.sent(nil), times: 2)

        stack.queue.sendWithoutReply(ascii("C1"))
        stack.queue.send(exchange(1, "Q", timeout: 10))
        stack.queue.sendWithoutReply(ascii("C2"))
        self.wait(for: [played, answered, secondCommandSent], timeout: 15)

        XCTAssertEqual(device.problems, [])
        XCTAssertEqual(stack.delegate.calls, [.opened, .answered(1, ascii("R"))])
        XCTAssertEqual(
            stack.observer.tagsWithoutRaw,
            [.opened, .sent(nil), .sent(1), .answered(1), .sent(nil)]
        )
        XCTAssertEqual(
            stack.observer.events.filter { Tag($0.kind) != .raw }.compactMap { $0.bytes },
            [ascii("C1"), ascii("Q"), ascii("R"), ascii("C2")]
        )
    }

    // MARK: Filler bytes

    func testFillerBytesInFrontOfAReplyAreSetAsideButStayInTheRawLog() throws {
        let terminal = try self.makeTerminal()
        let device = Device(terminal)
        let matcher = TailScanMatcher(fillerBytes: [0xFF], requiresASCII: true, lengthUnit: .characters)
        let stack = self.makeStack(on: terminal, matcher: matcher)
        stack.queue.open()
        let played = device.play("device pads its reply") { device in
            if device.expect(ascii("F")) {
                device.send(Data([0xFF, 0x43]))
            }
        }
        let answered = stack.delegate.expectCalls(2)

        stack.queue.send(exchange(1, "F", reply: .exactly(1)))
        self.wait(for: [played, answered], timeout: 15)

        XCTAssertEqual(device.problems, [])
        XCTAssertEqual(stack.delegate.calls, [.opened, .answered(1, Data([0x43]))])
        XCTAssertEqual(stack.observer.bytes(of: .answered(1)), Data([0x43]))
        XCTAssertEqual(stack.observer.rawBytes, Data([0xFF, 0x43]))
        XCTAssertFalse(stack.observer.has(.unreadable(1)))
        XCTAssertEqual(stack.observer.tagsWithoutRaw, [.opened, .sent(1), .answered(1)])
    }

    // MARK: Closing

    func testClosingThroughTheQueueIsReportedBeforeCloseReturnsAndThePathCanBeReopenedAtOnce() throws {
        let terminal = try self.makeTerminal()
        let device = Device(terminal)
        let first = self.makeStack(on: terminal)
        first.queue.open()
        XCTAssertTrue(first.port.isOpen)

        first.queue.close()

        XCTAssertEqual(first.delegate.calls, [.opened, .closed(.requested)])
        XCTAssertEqual(first.delegate.records.map { $0.onMainThread }, [true, true])
        XCTAssertFalse(first.queue.isOpen)
        XCTAssertFalse(first.port.isOpen)
        XCTAssertEqual(first.observer.tagsWithoutRaw, [.opened, .closed(.requested)])

        // A new port and queue take the path at once, exclusive access included.
        let second = self.makeStack(on: terminal)
        second.queue.open()

        XCTAssertEqual(second.delegate.calls, [.opened])
        XCTAssertTrue(second.queue.isOpen)
        let played = device.play("device answers the new queue") { device in
            if device.expect(ascii("P")) {
                device.send(ascii("Y"))
            }
        }
        let answered = second.delegate.expectCalls(2)
        second.queue.send(exchange(1, "P"))
        self.wait(for: [played, answered], timeout: 15)

        XCTAssertEqual(device.problems, [])
        XCTAssertEqual(second.delegate.calls, [.opened, .answered(1, ascii("Y"))])
        XCTAssertEqual(first.delegate.calls, [.opened, .closed(.requested)])
    }

    func testTheSameQueueCanBeClosedAndOpenedAgainAndKeepsAnswering() throws {
        let terminal = try self.makeTerminal()
        let device = Device(terminal)
        let stack = self.makeStack(on: terminal)
        let firstSession = stack.delegate.expectCalls(2)
        stack.queue.open()
        // One script per session: a device reading from the pseudo-terminal while no port has it open
        // is told the line is hung up.
        let playedFirst = device.play("device answers the first session") { device in
            if device.expect(ascii("1")) {
                device.send(ascii("A"))
            }
        }
        stack.queue.send(exchange(1, "1"))
        self.wait(for: [playedFirst, firstSession], timeout: 15)

        stack.queue.close()
        XCTAssertEqual(stack.delegate.calls, [.opened, .answered(1, ascii("A")), .closed(.requested)])
        XCTAssertFalse(stack.port.isOpen)

        let secondSession = stack.delegate.expectCalls(5)
        stack.queue.open()
        XCTAssertEqual(stack.delegate.calls.last, .opened)
        let playedSecond = device.play("device answers the second session") { device in
            if device.expect(ascii("2")) {
                device.send(ascii("B"))
            }
        }
        stack.queue.send(exchange(2, "2"))
        self.wait(for: [playedSecond, secondSession], timeout: 15)

        XCTAssertEqual(device.problems, [])
        XCTAssertEqual(
            stack.delegate.calls,
            [.opened, .answered(1, ascii("A")), .closed(.requested), .opened, .answered(2, ascii("B"))]
        )
        XCTAssertTrue(stack.queue.isOpen)
    }

    func testTheDeviceHangingUpClosesTheQueueAsRemovedOnceAndTheExchangeInFlightIsNeverAnswered() throws {
        let terminal = try self.makeTerminal()
        let device = Device(terminal)
        let stack = self.makeStack(on: terminal)
        stack.queue.open()
        let played = device.play("device hangs up after reading the frame") { device in
            if device.expect(ascii("Q1")) {
                device.hangUp()
            }
        }
        let closed = stack.delegate.expectCalls(2)

        // The first exchange is on the wire and the second waits behind it.
        stack.queue.send(exchange(1, "Q1", timeout: 1))
        stack.queue.send(exchange(2, "Q2", timeout: 1))
        self.wait(for: [played, closed], timeout: 15)

        XCTAssertEqual(device.problems, [])
        XCTAssertEqual(stack.delegate.calls, [.opened, .closed(.removed)])
        XCTAssertEqual(stack.delegate.records.map { $0.onMainThread }, [true, true])
        XCTAssertFalse(stack.queue.isOpen)
        XCTAssertFalse(stack.port.isOpen)

        // Longer than the exchange's timeout: neither an answer nor a timeout shows up afterwards.
        self.settle(1.3)
        stack.queue.close()
        stack.queue.send(exchange(3, "Q3", timeout: 0.1))
        self.settle(0.3)

        XCTAssertEqual(stack.delegate.calls, [.opened, .closed(.removed)])
        XCTAssertEqual(stack.observer.tagsWithoutRaw, [.opened, .sent(1), .closed(.removed)])
    }

    // MARK: Exclusive access

    func testASecondPortAndQueueOnTheSamePathIsRefusedThroughTheQueue() throws {
        let terminal = try self.makeTerminal()
        let device = Device(terminal)
        let first = self.makeStack(on: terminal)
        let second = self.makeStack(on: terminal)
        first.queue.open()

        second.queue.open()

        let refusal = SerialCloseReason.failed(.exclusiveAccessDenied(path: terminal.devicePath))
        XCTAssertEqual(second.delegate.calls, [.closed(refusal)])
        XCTAssertEqual(second.delegate.records.map { $0.onMainThread }, [true])
        XCTAssertEqual(second.observer.tagsWithoutRaw, [.closed(refusal)])
        XCTAssertFalse(second.queue.isOpen)
        XCTAssertFalse(second.port.isOpen)

        // The refused queue writes nothing; the first one is untouched and works.
        second.queue.send(exchange(9, "refused", timeout: 0.1))
        let played = device.play("device answers the first queue only") { device in
            if device.expect(ascii("A")) {
                device.send(ascii("Z"))
                device.expectSilence(for: 0.2)
            }
        }
        let answered = first.delegate.expectCalls(2)
        first.queue.send(exchange(1, "A"))
        self.wait(for: [played, answered], timeout: 15)

        XCTAssertEqual(device.problems, [])
        XCTAssertEqual(first.delegate.calls, [.opened, .answered(1, ascii("Z"))])
        XCTAssertEqual(second.delegate.calls, [.closed(refusal)])
    }

    // MARK: A shared dispatch queue

    func testPortAndQueueSharingOneDispatchQueueAnswerManyExchangesInOrder() throws {
        let count = 50
        let terminal = try self.makeTerminal()
        let device = Device(terminal)
        let shared = DispatchQueue(label: "PortAndQueueTests.shared")
        let stack = self.makeStack(on: terminal, sharedQueue: shared)
        stack.queue.open()
        let frames = (1...count).map { self.numberedFrame($0) }
        let replies = (1...count).map { self.numberedReply($0) }
        let played = device.play("device answers \(count) exchanges") { device in
            for number in 0..<count {
                guard device.expect(frames[number]) else {
                    return
                }
                device.send(replies[number])
            }
        }
        let allAnswered = stack.delegate.expectCalls(count + 1)

        for number in 1...count {
            stack.queue.send(exchange(number, frames[number - 1], reply: .exactly(3), timeout: 10))
        }
        self.wait(for: [played, allAnswered], timeout: 30)

        XCTAssertEqual(device.problems, [])
        var expected: [TransportSpy.Call] = [.opened]
        for number in 1...count {
            expected.append(.answered(number, replies[number - 1]))
        }
        XCTAssertEqual(stack.delegate.calls, expected)
        XCTAssertTrue(stack.delegate.records.allSatisfy { $0.onMainThread })
        XCTAssertTrue(stack.queue.isOpen)

        stack.queue.close()

        XCTAssertEqual(stack.delegate.calls.last, .closed(.requested))
        XCTAssertFalse(stack.queue.isOpen)
        XCTAssertFalse(stack.port.isOpen)
    }

    // MARK: Throughput

    func testTwoHundredPolledExchangesAreAllAnsweredAndIdleWorkRunsBetweenTwoPolls() throws {
        let rounds = 200
        let stagedAfter = 100
        let terminal = try self.makeTerminal()
        let device = Device(terminal)
        let stack = self.makeStack(on: terminal)
        let allAnswered = stack.delegate.expectCalls(rounds + 1)

        // Everything below runs on the main queue, where the delegate is called.
        var answeredNumbers: [Int] = []
        var answeredWhenIdleRan: [Int] = []
        var idleWorkOnMain: [Bool] = []
        stack.delegate.onCall = { [weak stack] call in
            guard case .answered(let number, let reply) = call else {
                return
            }
            if reply != Data([0x52, UInt8(number % 256)]) {
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
                stack?.queue.send(exchange(next, Data([0x50, UInt8(next % 256)]), reply: .exactly(2), timeout: 10))
            }
        }
        stack.queue.open()
        let played = device.play("device answers every poll") { device in
            for number in 1...rounds {
                let tag = UInt8(number % 256)
                guard device.expect(Data([0x50, tag])) else {
                    return
                }
                device.send(Data([0x52, tag]))
            }
        }

        stack.queue.send(exchange(1, Data([0x50, 0x01]), reply: .exactly(2), timeout: 10))
        self.wait(for: [played, allAnswered], timeout: 60)
        self.settle(0.1)

        XCTAssertEqual(device.problems, [])
        XCTAssertEqual(answeredNumbers, Array(1...rounds))
        XCTAssertEqual(stack.delegate.calls.count, rounds + 1)
        XCTAssertEqual(stack.delegate.calls.first, .opened)
        XCTAssertFalse(stack.observer.has(.timedOut(1)))
        XCTAssertFalse(stack.observer.has(.late))
        XCTAssertFalse(stack.observer.has(.unsolicited))
        // The idle work ran once, on the main queue, after the poll it was staged behind and before
        // the next poll's answer: it was not starved until the loop ended.
        XCTAssertEqual(answeredWhenIdleRan, [stagedAfter])
        XCTAssertEqual(idleWorkOnMain, [true])
    }
}
