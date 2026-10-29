//
//  StreamCloseOrderingTests.swift
//  SerialPortSwiftTests
//

import Foundation
import SerialPortSwift
import SerialPortSwiftSimulation
import XCTest

/// Records what a stream tells its delegate, in the order it tells it. The hooks run on the thread of
/// each call, after it is recorded and with no lock held.
private final class OrderLog: SerialByteStreamDelegate {
    enum Event: Equatable {
        case opened
        case received(Data)
        case closed(SerialCloseReason)
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    private var receiveHook: (() -> Void)?
    private var closeHook: (() -> Void)?

    var onReceive: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return receiveHook
        }
        set {
            lock.lock()
            receiveHook = newValue
            lock.unlock()
        }
    }

    var onClose: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return closeHook
        }
        set {
            lock.lock()
            closeHook = newValue
            lock.unlock()
        }
    }

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var closeCount: Int {
        return events.filter { if case .closed = $0 { return true } else { return false } }.count
    }

    /// How many chunks the delegate was handed after it had heard of a close.
    var chunksAfterAClose: Int {
        var closed = false
        var count = 0
        for event in events {
            switch event {
            case .closed:
                closed = true
            case .received:
                if closed {
                    count += 1
                }
            case .opened:
                closed = false
            }
        }
        return count
    }

    func streamDidOpen(_ stream: SerialByteStream) {
        add(.opened)
    }

    func stream(_ stream: SerialByteStream, didReceive bytes: Data) {
        add(.received(bytes))
        onReceive?()
    }

    func streamDidClose(_ stream: SerialByteStream, reason: SerialCloseReason) {
        add(.closed(reason))
        onClose?()
    }

    private func add(_ event: Event) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }
}

/// A device that answers every frame with the frame itself, and remembers the frames.
private final class EchoDevice: SerialDeviceSimulator {
    private let lock = NSLock()
    private var recorded: [Data] = []

    var frames: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func reply(to frame: Data) -> Data? {
        lock.lock()
        recorded.append(frame)
        lock.unlock()
        return frame
    }
}

private let chunk = Data([0x41])

final class StreamCloseOrderingTests: XCTestCase {
    private static let timeout: TimeInterval = 10

    /// Waits until the queue has run what was handed to it, and then a little: timers that were already
    /// due may fire after a barrier.
    private func drain(_ queue: DispatchQueue) {
        queue.sync {}
        queue.sync {}
        queue.sync {}
        Thread.sleep(forTimeInterval: 0.001)
    }

    /// Holds `queue` busy until the returned semaphore is signalled.
    private func hold(_ queue: DispatchQueue) -> DispatchSemaphore {
        let busy = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        queue.async {
            busy.signal()
            _ = release.wait(timeout: .now() + StreamCloseOrderingTests.timeout)
        }
        XCTAssertEqual(busy.wait(timeout: .now() + StreamCloseOrderingTests.timeout), .success)
        return release
    }

    // MARK: - SimulatedByteStream

    func testASimulatedWriteQueuedBeforeACloseAndAnOpenNeverReachesTheNewSession() {
        let queue = DispatchQueue(label: "StreamCloseOrderingTests.simulated")
        let device = EchoDevice()
        let stream = SimulatedByteStream(device: device, replyLatency: 0, queue: queue)
        let log = OrderLog()
        stream.delegate = log
        stream.open()
        let release = hold(queue)

        stream.write(Data([0xA1]))
        stream.close()
        stream.open()
        release.signal()
        let received = DispatchSemaphore(value: 0)
        log.onReceive = { received.signal() }
        stream.write(Data([0xB2]))

        XCTAssertEqual(received.wait(timeout: .now() + StreamCloseOrderingTests.timeout), .success)
        drain(queue)
        XCTAssertEqual(device.frames, [Data([0xB2])])
        XCTAssertEqual(log.events, [.opened, .closed(.requested), .opened, .received(Data([0xB2]))])
    }

    func testASimulatedWriteQueuedBeforeARemovalAndAnOpenNeverReachesTheNewSession() {
        let queue = DispatchQueue(label: "StreamCloseOrderingTests.simulated")
        let device = EchoDevice()
        let stream = SimulatedByteStream(device: device, replyLatency: 0, queue: queue)
        stream.open()
        let release = hold(queue)

        stream.write(Data([0xA1]))
        stream.simulateRemoval()
        stream.open()
        release.signal()
        drain(queue)

        XCTAssertEqual(device.frames, [])
        XCTAssertTrue(stream.isOpen)
    }

    func testNothingReachesTheDelegateOfASimulatedStreamAfterItsCloseWasReported() {
        for iteration in 0..<300 {
            let queue = DispatchQueue(label: "StreamCloseOrderingTests.simulated")
            let stream = SimulatedByteStream(device: EchoDevice(), replyLatency: 0, queue: queue)
            let log = OrderLog()
            stream.delegate = log
            stream.open()
            let start = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) {
                start.wait()
                var written = 0
                while stream.isOpen && written < 2000 {
                    stream.write(Data([0x41]))
                    written += 1
                }
            }
            DispatchQueue.global().async(group: group) {
                start.wait()
                usleep(UInt32(iteration % 8) * 40)
                if iteration % 2 == 0 {
                    stream.close()
                } else {
                    stream.simulateRemoval()
                }
            }
            start.signal()
            start.signal()
            XCTAssertEqual(group.wait(timeout: .now() + StreamCloseOrderingTests.timeout), .success)
            drain(queue)

            XCTAssertEqual(log.closeCount, 1, "iteration \(iteration)")
            XCTAssertEqual(log.chunksAfterAClose, 0, "iteration \(iteration)")
        }
    }

    func testASimulatedCloseIsNotReportedWhileADeliveryIsInProgress() {
        let queue = DispatchQueue(label: "StreamCloseOrderingTests.simulated")
        let stream = SimulatedByteStream(device: EchoDevice(), replyLatency: 0, queue: queue)
        let log = OrderLog()
        let inside = DispatchSemaphore(value: 0)
        let leave = DispatchSemaphore(value: 0)
        let closeReported = DispatchSemaphore(value: 0)
        log.onReceive = {
            inside.signal()
            _ = leave.wait(timeout: .now() + StreamCloseOrderingTests.timeout)
        }
        log.onClose = { closeReported.signal() }
        stream.delegate = log
        stream.open()
        stream.write(chunk)
        XCTAssertEqual(inside.wait(timeout: .now() + StreamCloseOrderingTests.timeout), .success)

        DispatchQueue.global().async { stream.close() }

        // The chunk is still being handed over: the close has to wait for it.
        XCTAssertEqual(closeReported.wait(timeout: .now() + 0.2), .timedOut)
        leave.signal()
        XCTAssertEqual(closeReported.wait(timeout: .now() + StreamCloseOrderingTests.timeout), .success)
        XCTAssertEqual(log.events, [.opened, .received(chunk), .closed(.requested)])
    }

    func testASimulatedDelegateMayCloseTheStreamFromInsideADelivery() {
        let queue = DispatchQueue(label: "StreamCloseOrderingTests.simulated")
        let stream = SimulatedByteStream(device: EchoDevice(), replyLatency: 0, queue: queue)
        let log = OrderLog()
        let closeReported = DispatchSemaphore(value: 0)
        log.onReceive = { stream.close() }
        log.onClose = { closeReported.signal() }
        stream.delegate = log
        stream.open()

        stream.write(chunk)

        XCTAssertEqual(closeReported.wait(timeout: .now() + StreamCloseOrderingTests.timeout), .success)
        XCTAssertEqual(log.events, [.opened, .received(chunk), .closed(.requested)])
        XCTAssertFalse(stream.isOpen)
    }

    func testASimulatedDelegateMayRemoveTheDeviceFromInsideADelivery() {
        let queue = DispatchQueue(label: "StreamCloseOrderingTests.simulated")
        let stream = SimulatedByteStream(device: EchoDevice(), replyLatency: 0, queue: queue)
        let log = OrderLog()
        let closeReported = DispatchSemaphore(value: 0)
        log.onReceive = { stream.simulateRemoval() }
        log.onClose = { closeReported.signal() }
        stream.delegate = log
        stream.open()

        stream.write(chunk)
        stream.write(chunk)

        XCTAssertEqual(closeReported.wait(timeout: .now() + StreamCloseOrderingTests.timeout), .success)
        drain(queue)
        XCTAssertEqual(log.events, [.opened, .received(chunk), .closed(.removed)])
    }

    // MARK: - ReplayByteStream

    func testAReplayWriteQueuedBeforeACloseAndAnOpenIsNeitherRecordedNorAnswered() {
        let queue = DispatchQueue(label: "StreamCloseOrderingTests.replay")
        let stream = ReplayByteStream(
            script: [.reply(with: [ReplayChunk(Data([0xEE]))]), .silence()],
            queue: queue
        )
        let log = OrderLog()
        stream.delegate = log
        stream.open()
        let release = hold(queue)

        stream.write(Data([0xA1]))
        stream.close()
        stream.open()
        release.signal()
        drain(queue)

        XCTAssertEqual(stream.writes, [])
        XCTAssertEqual(stream.remainingSteps, 2)

        let received = DispatchSemaphore(value: 0)
        log.onReceive = { received.signal() }
        stream.write(Data([0xB2]))

        XCTAssertEqual(received.wait(timeout: .now() + StreamCloseOrderingTests.timeout), .success)
        XCTAssertEqual(stream.writes.map { $0.bytes }, [Data([0xB2])])
        XCTAssertEqual(stream.remainingSteps, 1)
        XCTAssertEqual(log.events, [.opened, .closed(.requested), .opened, .received(Data([0xEE]))])
    }

    func testNothingReachesTheDelegateOfAReplayStreamAfterItsCloseWasReported() {
        for iteration in 0..<300 {
            let queue = DispatchQueue(label: "StreamCloseOrderingTests.replay")
            let stream = ReplayByteStream(queue: queue)
            let log = OrderLog()
            stream.delegate = log
            stream.open()
            for _ in 0..<80 {
                stream.receive(chunk)
            }
            let start = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) {
                start.wait()
                usleep(UInt32(iteration % 8) * 40)
                stream.close()
            }
            DispatchQueue.global().async(group: group) {
                start.wait()
                for _ in 0..<80 {
                    stream.receive(chunk)
                }
            }
            start.signal()
            start.signal()
            XCTAssertEqual(group.wait(timeout: .now() + StreamCloseOrderingTests.timeout), .success)
            drain(queue)

            XCTAssertEqual(log.closeCount, 1, "iteration \(iteration)")
            XCTAssertEqual(log.chunksAfterAClose, 0, "iteration \(iteration)")
        }
    }

    func testAReplayEndRacingACloseReportsOneCloseAndNothingAfterIt() {
        for iteration in 0..<300 {
            let queue = DispatchQueue(label: "StreamCloseOrderingTests.replay")
            let stream = ReplayByteStream(queue: queue)
            let log = OrderLog()
            stream.delegate = log
            stream.open()
            for _ in 0..<50 {
                stream.receive(chunk)
            }
            stream.end(.removed)
            for _ in 0..<50 {
                stream.receive(chunk)
            }
            let start = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) {
                start.wait()
                usleep(UInt32(iteration % 8) * 40)
                stream.close()
            }
            start.signal()
            XCTAssertEqual(group.wait(timeout: .now() + StreamCloseOrderingTests.timeout), .success)
            drain(queue)

            XCTAssertEqual(log.closeCount, 1, "iteration \(iteration)")
            XCTAssertEqual(log.chunksAfterAClose, 0, "iteration \(iteration)")
            XCTAssertFalse(stream.isOpen)
        }
    }

    func testAReplayCloseIsNotReportedWhileADeliveryIsInProgress() {
        let stream = ReplayByteStream()
        let log = OrderLog()
        let inside = DispatchSemaphore(value: 0)
        let leave = DispatchSemaphore(value: 0)
        let closeReported = DispatchSemaphore(value: 0)
        log.onReceive = {
            inside.signal()
            _ = leave.wait(timeout: .now() + StreamCloseOrderingTests.timeout)
        }
        log.onClose = { closeReported.signal() }
        stream.delegate = log
        stream.open()
        stream.receive(chunk)
        XCTAssertEqual(inside.wait(timeout: .now() + StreamCloseOrderingTests.timeout), .success)

        DispatchQueue.global().async { stream.close() }

        // The chunk is still being handed over: the close has to wait for it.
        XCTAssertEqual(closeReported.wait(timeout: .now() + 0.2), .timedOut)
        leave.signal()
        XCTAssertEqual(closeReported.wait(timeout: .now() + StreamCloseOrderingTests.timeout), .success)
        XCTAssertEqual(log.events, [.opened, .received(chunk), .closed(.requested)])
    }

    func testAReplayDelegateMayCloseTheStreamFromInsideADelivery() {
        let stream = ReplayByteStream()
        let log = OrderLog()
        let closeReported = DispatchSemaphore(value: 0)
        log.onReceive = { stream.close() }
        log.onClose = { closeReported.signal() }
        stream.delegate = log
        stream.open()

        stream.receive(chunk)
        stream.receive(chunk)

        XCTAssertEqual(closeReported.wait(timeout: .now() + StreamCloseOrderingTests.timeout), .success)
        XCTAssertEqual(log.events, [.opened, .received(chunk), .closed(.requested)])
        XCTAssertFalse(stream.isOpen)
    }

    func testAReplayDelegateMayOpenTheStreamAgainFromInsideTheReportOfAnEnd() {
        let stream = ReplayByteStream()
        let log = OrderLog()
        let closeReported = DispatchSemaphore(value: 0)
        log.onClose = {
            stream.open()
            closeReported.signal()
        }
        stream.delegate = log
        stream.open()

        stream.end(.removed)

        XCTAssertEqual(closeReported.wait(timeout: .now() + StreamCloseOrderingTests.timeout), .success)
        XCTAssertEqual(log.events, [.opened, .closed(.removed), .opened])
        XCTAssertTrue(stream.isOpen)
    }
}
