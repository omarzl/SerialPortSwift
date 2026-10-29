//
//  ReplayByteStreamTests.swift
//  SerialPortSwiftTests
//

import SerialPortSwift
import SerialPortSwiftSimulation
import XCTest

/// Records what a stream tells its delegate, with the time and thread of each call.
private final class StreamDelegateSpy: SerialByteStreamDelegate {
    enum Call: Equatable {
        case opened
        case received(Data)
        case closed(SerialCloseReason)
    }

    struct Record {
        let call: Call
        let date: Date
        let onMainThread: Bool
        let onQueue: Bool
    }

    private let lock = NSLock()
    private var recorded: [Record] = []
    private let queueKey: DispatchSpecificKey<Bool>?

    init(queueKey: DispatchSpecificKey<Bool>? = nil) {
        self.queueKey = queueKey
    }

    var records: [Record] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var calls: [Call] {
        return records.map { $0.call }
    }

    var received: [Data] {
        return calls.compactMap { call in
            if case .received(let bytes) = call {
                return bytes
            }
            return nil
        }
    }

    private func add(_ call: Call) {
        var onQueue = false
        if let key = queueKey {
            onQueue = DispatchQueue.getSpecific(key: key) != nil
        }
        lock.lock()
        recorded.append(Record(call: call, date: Date(), onMainThread: Thread.isMainThread, onQueue: onQueue))
        lock.unlock()
    }

    func streamDidOpen(_ stream: SerialByteStream) {
        add(.opened)
    }

    func stream(_ stream: SerialByteStream, didReceive bytes: Data) {
        add(.received(bytes))
    }

    func streamDidClose(_ stream: SerialByteStream, reason: SerialCloseReason) {
        add(.closed(reason))
    }
}

final class ReplayByteStreamTests: XCTestCase {
    private func bytes(_ string: String) -> Data {
        return Data(string.utf8)
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

    private func openStream(
        script: [ReplayStep] = [],
        queue: DispatchQueue? = nil,
        queueKey: DispatchSpecificKey<Bool>? = nil
    ) -> (ReplayByteStream, StreamDelegateSpy) {
        let stream = ReplayByteStream(script: script, queue: queue)
        let spy = StreamDelegateSpy(queueKey: queueKey)
        stream.delegate = spy
        stream.open()
        return (stream, spy)
    }

    // MARK: - Open and close

    func testItIsNamedAndStartsClosed() {
        XCTAssertEqual(ReplayByteStream().name, "replay")
        XCTAssertEqual(ReplayByteStream(name: "scripted").name, "scripted")
        XCTAssertFalse(ReplayByteStream().isOpen)
    }

    func testOpenReportsBeforeItReturns() {
        let stream = ReplayByteStream()
        let spy = StreamDelegateSpy()
        stream.delegate = spy

        stream.open()

        XCTAssertEqual(spy.calls, [.opened])
        XCTAssertTrue(spy.records[0].onMainThread)
        XCTAssertTrue(stream.isOpen)
    }

    func testOpeningAnOpenStreamReportsNothing() {
        let (stream, spy) = openStream()

        stream.open()

        XCTAssertEqual(spy.calls, [.opened])
    }

    func testAnOpenFailureIsReportedBeforeOpenReturnsAndLeavesTheStreamClosed() {
        let failure = SerialStreamError.openFailed(path: "/dev/none", code: 2)
        let stream = ReplayByteStream(openFailure: failure)
        let spy = StreamDelegateSpy()
        stream.delegate = spy

        stream.open()

        XCTAssertEqual(spy.calls, [.closed(.failed(failure))])
        XCTAssertFalse(stream.isOpen)

        stream.open()
        XCTAssertEqual(spy.calls, [.closed(.failed(failure)), .closed(.failed(failure))])
    }

    func testCloseReportsRequestedBeforeItReturns() {
        let (stream, spy) = openStream()

        stream.close()

        XCTAssertEqual(spy.calls, [.opened, .closed(.requested)])
        XCTAssertFalse(stream.isOpen)
    }

    func testClosingAClosedStreamReportsNothing() {
        let stream = ReplayByteStream()
        let spy = StreamDelegateSpy()
        stream.delegate = spy

        stream.close()
        XCTAssertEqual(spy.calls, [])

        stream.open()
        stream.close()
        stream.close()
        XCTAssertEqual(spy.calls, [.opened, .closed(.requested)])
    }

    func testItOpensAgainAfterBeingClosed() {
        let (stream, spy) = openStream()
        stream.close()

        stream.open()

        XCTAssertEqual(spy.calls, [.opened, .closed(.requested), .opened])
        XCTAssertTrue(stream.isOpen)
    }

    // MARK: - Writes and the script

    func testWritesAreRecordedInOrderWithTheirDate() {
        let (stream, _) = openStream(script: [.silence(), .silence(), .silence()])
        let before = Date()

        stream.write(bytes("one"))
        stream.write(bytes("two"))
        stream.write(bytes("three"))
        waitUntil { stream.writes.count == 3 }
        let after = Date()

        XCTAssertEqual(stream.writes.map { $0.bytes }, [bytes("one"), bytes("two"), bytes("three")])
        for write in stream.writes {
            XCTAssertGreaterThanOrEqual(write.date, before)
            XCTAssertLessThanOrEqual(write.date, after)
        }
    }

    func testAWriteIsAnsweredWithTheRepliesOfTheNextStepAtTheirOffsets() {
        let (stream, spy) = openStream(script: [
            .reply(with: [ReplayChunk(bytes("A")), ReplayChunk(bytes("B"), at: 0.1)])
        ])
        let before = Date()

        stream.write(bytes("go"))
        waitUntil { spy.received.count == 2 }

        XCTAssertEqual(spy.received, [bytes("A"), bytes("B")])
        let times = spy.records.filter { $0.call != .opened }.map { $0.date }
        XCTAssertGreaterThanOrEqual(times[1].timeIntervalSince(before), 0.1 - 0.01)
        XCTAssertEqual(stream.writes.map { $0.matchedExpectation }, [true])
    }

    func testAMatchingExpectationIsMarkedMatchedAndADifferentOneIsNotButStillAnswered() {
        let (stream, spy) = openStream(script: [
            .reply(to: bytes("A"), with: [ReplayChunk(bytes("1"))]),
            .reply(to: bytes("B"), with: [ReplayChunk(bytes("2"))])
        ])

        stream.write(bytes("A"))
        stream.write(bytes("X"))
        waitUntil { spy.received.count == 2 }

        XCTAssertEqual(stream.writes.map { $0.matchedExpectation }, [true, false])
        XCTAssertEqual(spy.received, [bytes("1"), bytes("2")])
    }

    func testAStepWithoutAnExpectationAcceptsAnyWrite() {
        let (stream, _) = openStream(script: [.silence()])

        stream.write(bytes("anything"))
        waitUntil { stream.writes.count == 1 }

        XCTAssertEqual(stream.writes.map { $0.matchedExpectation }, [true])
    }

    func testASilenceStepUsesUpAWriteWithoutAnswering() {
        let (stream, spy) = openStream(script: [
            .silence(after: bytes("A")),
            .reply(with: [ReplayChunk(bytes("2"))])
        ])

        stream.write(bytes("A"))
        stream.write(bytes("B"))
        waitUntil { spy.received.count == 1 }

        XCTAssertEqual(spy.received, [bytes("2")])
        XCTAssertEqual(stream.writes.map { $0.matchedExpectation }, [true, true])
        XCTAssertEqual(stream.remainingSteps, 0)
    }

    func testAWriteWithTheScriptUsedUpIsRecordedUnmatchedAndGetsNoAnswer() {
        let (stream, spy) = openStream()

        stream.write(bytes("extra"))
        waitUntil { stream.writes.count == 1 }
        settle(0.05)

        XCTAssertEqual(stream.writes.map { $0.bytes }, [bytes("extra")])
        XCTAssertEqual(stream.writes.map { $0.matchedExpectation }, [false])
        XCTAssertEqual(spy.received, [])
    }

    func testAppendAddsStepsAtTheEndAndRemainingStepsCountsTheUnusedOnes() {
        let (stream, spy) = openStream(script: [.silence()])
        XCTAssertEqual(stream.remainingSteps, 1)

        stream.append([.reply(with: [ReplayChunk(bytes("Z"))]), .silence()])
        XCTAssertEqual(stream.remainingSteps, 3)

        stream.write(bytes("1"))
        stream.write(bytes("2"))
        waitUntil { spy.received.count == 1 }

        XCTAssertEqual(stream.remainingSteps, 1)
        XCTAssertEqual(spy.received, [bytes("Z")])
    }

    func testAWriteToAClosedStreamIsIgnoredAndDoesNotUseUpAStep() {
        let stream = ReplayByteStream(script: [.silence()])

        stream.write(bytes("ignored"))
        settle(0.05)

        XCTAssertEqual(stream.writes, [])
        XCTAssertEqual(stream.remainingSteps, 1)
    }

    func testRepliesOfAnEarlierStepKeepComingWhileALaterStepIsAnswered() {
        let (stream, spy) = openStream(script: [
            .reply(with: [ReplayChunk(bytes("late"), at: 0.3)]),
            .reply(with: [ReplayChunk(bytes("early"))])
        ])

        stream.write(bytes("1"))
        stream.write(bytes("2"))
        waitUntil { spy.received.count == 2 }

        XCTAssertEqual(spy.received, [bytes("early"), bytes("late")])
    }

    func testChunksDueTogetherArriveInScriptOrderAndOthersInOffsetOrder() {
        let (stream, spy) = openStream(script: [
            .reply(with: [
                ReplayChunk(bytes("D"), at: 0.1),
                ReplayChunk(bytes("A"), at: 0.05),
                ReplayChunk(bytes("B"), at: 0.05),
                ReplayChunk(bytes("C"), at: 0.05),
                ReplayChunk(bytes("0"), at: 0)
            ])
        ])

        stream.write(bytes("go"))
        waitUntil { spy.received.count == 5 }

        XCTAssertEqual(spy.received, [bytes("0"), bytes("A"), bytes("B"), bytes("C"), bytes("D")])
    }

    // MARK: - Pushing bytes and closes

    func testReceiveDeliversAChunkAfterTheDelay() {
        let (stream, spy) = openStream()
        let before = Date()

        stream.receive(bytes("pushed"), after: 0.1)
        waitUntil { !spy.received.isEmpty }

        XCTAssertEqual(spy.received, [bytes("pushed")])
        XCTAssertGreaterThanOrEqual(spy.records[1].date.timeIntervalSince(before), 0.1 - 0.01)
    }

    func testReceiveWithoutADelayStillArrivesLaterAndOnTheStreamsOwnQueue() {
        let (stream, spy) = openStream()

        stream.receive(bytes("now"))
        waitUntil { !spy.received.isEmpty }

        XCTAssertFalse(spy.records[1].onMainThread)
    }

    func testReceiveIsIgnoredWhenTheStreamIsClosedByThen() {
        let (stream, spy) = openStream()

        stream.receive(bytes("late"), after: 0.1)
        stream.close()
        settle(0.3)

        XCTAssertEqual(spy.received, [])
    }

    func testReceiveOnAClosedStreamIsIgnored() {
        let stream = ReplayByteStream()
        let spy = StreamDelegateSpy()
        stream.delegate = spy

        stream.receive(bytes("nobody home"))
        settle(0.1)

        XCTAssertEqual(spy.calls, [])
    }

    func testCloseCancelsTheRepliesStillOnTheirWay() {
        let (stream, spy) = openStream(script: [.reply(with: [ReplayChunk(bytes("late"), at: 0.2)])])
        stream.write(bytes("go"))
        waitUntil { stream.writes.count == 1 }

        stream.close()
        settle(0.4)

        XCTAssertEqual(spy.calls, [.opened, .closed(.requested)])
    }

    func testRepliesCancelledByACloseDoNotComeBackWhenItOpensAgain() {
        let (stream, spy) = openStream(script: [.reply(with: [ReplayChunk(bytes("stale"), at: 0.2)])])
        stream.write(bytes("go"))
        waitUntil { stream.writes.count == 1 }

        stream.close()
        stream.open()
        settle(0.4)

        XCTAssertEqual(spy.received, [])
    }

    func testEndClosesTheStreamWithTheReasonOnItsOwnQueue() {
        let (stream, spy) = openStream()

        stream.end(.removed, after: 0.05)
        waitUntil { spy.calls.count == 2 }

        XCTAssertEqual(spy.calls, [.opened, .closed(.removed)])
        XCTAssertFalse(spy.records[1].onMainThread)
        XCTAssertFalse(stream.isOpen)
    }

    func testEndCarriesAFailure() {
        let (stream, spy) = openStream()
        let failure = SerialStreamError.readFailed(code: 5)

        stream.end(.failed(failure))
        waitUntil { spy.calls.count == 2 }

        XCTAssertEqual(spy.calls.last, .closed(.failed(failure)))
    }

    func testNothingScheduledAfterAnEndIsDelivered() {
        let (stream, spy) = openStream()

        stream.receive(bytes("before"), after: 0.02)
        stream.end(.removed, after: 0.1)
        stream.receive(bytes("after"), after: 0.2)
        waitUntil { spy.calls.count == 3 }
        settle(0.3)

        XCTAssertEqual(spy.calls, [.opened, .received(bytes("before")), .closed(.removed)])
    }

    func testEndOnAClosedStreamIsIgnored() {
        let stream = ReplayByteStream()
        let spy = StreamDelegateSpy()
        stream.delegate = spy

        stream.end(.removed)
        settle(0.1)

        XCTAssertEqual(spy.calls, [])
    }

    func testAnEndIsIgnoredWhenTheStreamWasClosedByThen() {
        let (stream, spy) = openStream()

        stream.end(.removed, after: 0.1)
        stream.close()
        settle(0.3)

        XCTAssertEqual(spy.calls, [.opened, .closed(.requested)])
    }

    // MARK: - Threads

    func testDeliveriesRunOnTheQueueItWasGiven() {
        let key = DispatchSpecificKey<Bool>()
        let queue = DispatchQueue(label: "ReplayByteStreamTests.queue")
        queue.setSpecific(key: key, value: true)
        let (stream, spy) = openStream(
            script: [.reply(with: [ReplayChunk(bytes("A"))])],
            queue: queue,
            queueKey: key
        )

        stream.write(bytes("go"))
        stream.receive(bytes("B"), after: 0.02)
        stream.end(.removed, after: 0.05)
        waitUntil { spy.calls.count == 4 }

        let deliveries = spy.records.dropFirst()
        XCTAssertEqual(deliveries.count, 3)
        XCTAssertTrue(deliveries.allSatisfy { $0.onQueue })
    }
}
