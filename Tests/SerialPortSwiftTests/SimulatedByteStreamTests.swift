//
//  SimulatedByteStreamTests.swift
//  SerialPortSwiftTests
//

import Foundation
import SerialPortSwift
import SerialPortSwiftSimulation
import XCTest

/// A device that answers from a table and remembers every frame it was asked about.
private final class TableDevice: SerialDeviceSimulator {
    private let lock = NSLock()
    private var table: [Data: Data]
    private var recorded: [Data] = []
    private var onFrame: ((Int) -> Void)?

    init(table: [Data: Data] = [:]) {
        self.table = table
    }

    var frames: [Data] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.recorded
    }

    func setReply(_ reply: Data?, to frame: Data) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.table[frame] = reply
    }

    /// Calls `handler` with the number of frames seen so far, after every frame.
    func observeFrames(_ handler: @escaping (Int) -> Void) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.onFrame = handler
    }

    func reply(to frame: Data) -> Data? {
        self.lock.lock()
        self.recorded.append(frame)
        let count = self.recorded.count
        let reply = self.table[frame]
        let handler = self.onFrame
        self.lock.unlock()

        handler?(count)
        return reply
    }
}

/// Records what a stream tells its delegate, and where and when it did.
private final class StreamRecorder: SerialByteStreamDelegate {
    enum Event: Equatable {
        case opened
        case received(Data)
        case closed(SerialCloseReason)
    }

    private let lock = NSLock()
    private let queueKey: DispatchSpecificKey<UInt8>?
    private var recordedEvents: [Event] = []
    private var receiveTimes: [UInt64] = []
    private var receivedOffQueue: [Bool] = []
    private var receivedOnMain: [Bool] = []
    private var chunkTarget = 0
    private var chunkExpectation: XCTestExpectation?
    private var anyChunkExpectation: XCTestExpectation?

    /// `queueKey` is set on the queue the stream is expected to deliver on.
    init(queueKey: DispatchSpecificKey<UInt8>? = nil) {
        self.queueKey = queueKey
    }

    var events: [Event] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.recordedEvents
    }

    var chunks: [Data] {
        return self.events.compactMap { event -> Data? in
            if case let .received(bytes) = event {
                return bytes
            }
            return nil
        }
    }

    /// Uptime, in nanoseconds, at which each chunk arrived.
    var chunkTimes: [UInt64] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.receiveTimes
    }

    var allChunksArrivedOnTheExpectedQueue: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return !self.receivedOffQueue.contains(true)
    }

    var anyChunkArrivedOnMain: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.receivedOnMain.contains(true)
    }

    /// An expectation fulfilled once `count` chunks have arrived (or at once, if they already have).
    func expectChunks(_ count: Int, test: XCTestCase) -> XCTestExpectation {
        let expectation = test.expectation(description: "\(count) chunks")
        self.lock.lock()
        let arrived = self.receiveTimes.count
        if arrived < count {
            self.chunkTarget = count
            self.chunkExpectation = expectation
        }
        self.lock.unlock()
        if arrived >= count {
            expectation.fulfill()
        }
        return expectation
    }

    /// An inverted expectation: it fails the test if a chunk arrives while it is waited on.
    func expectNoChunk(test: XCTestCase) -> XCTestExpectation {
        let expectation = test.expectation(description: "no chunk")
        expectation.isInverted = true
        self.lock.lock()
        self.anyChunkExpectation = expectation
        self.lock.unlock()
        return expectation
    }

    func streamDidOpen(_ stream: SerialByteStream) {
        self.record(.opened)
    }

    func stream(_ stream: SerialByteStream, didReceive bytes: Data) {
        let now = DispatchTime.now().uptimeNanoseconds
        let onMain = Thread.isMainThread
        var off = false
        if let key = self.queueKey {
            off = DispatchQueue.getSpecific(key: key) == nil
        }

        self.lock.lock()
        self.recordedEvents.append(.received(bytes))
        self.receiveTimes.append(now)
        self.receivedOnMain.append(onMain)
        self.receivedOffQueue.append(off)
        let reached = self.receiveTimes.count >= self.chunkTarget ? self.chunkExpectation : nil
        let any = self.anyChunkExpectation
        self.chunkExpectation = reached == nil ? self.chunkExpectation : nil
        self.anyChunkExpectation = nil
        self.lock.unlock()

        reached?.fulfill()
        any?.fulfill()
    }

    func streamDidClose(_ stream: SerialByteStream, reason: SerialCloseReason) {
        self.record(.closed(reason))
    }

    private func record(_ event: Event) {
        self.lock.lock()
        self.recordedEvents.append(event)
        self.lock.unlock()
    }
}

final class SimulatedByteStreamTests: XCTestCase {
    private static let timeout: TimeInterval = 10

    private let queueKey = DispatchSpecificKey<UInt8>()
    private var queue: DispatchQueue!

    override func setUp() {
        super.setUp()
        self.queue = DispatchQueue(label: "SimulatedByteStreamTests")
        self.queue.setSpecific(key: self.queueKey, value: 1)
    }

    override func tearDown() {
        self.queue = nil
        super.tearDown()
    }

    private func bytes(_ values: UInt8...) -> Data {
        return Data(values)
    }

    /// Waits until the stream's queue has run everything handed to it so far.
    private func drainQueue() {
        self.queue.sync {}
    }

    private func makeStream(
        _ device: SerialDeviceSimulator,
        latency: TimeInterval = 0
    ) -> (stream: SimulatedByteStream, recorder: StreamRecorder) {
        let stream = SimulatedByteStream(device: device, replyLatency: latency, queue: self.queue)
        let recorder = StreamRecorder(queueKey: self.queueKey)
        stream.delegate = recorder
        return (stream, recorder)
    }

    // MARK: - Replies

    func testAReplyArrivesAfterTheLatencyOnTheStreamQueueAsOneChunk() {
        let reply = bytes(0x10, 0x20, 0x30, 0x40)
        let device = TableDevice(table: [bytes(0x01): reply])
        let (stream, recorder) = self.makeStream(device, latency: 0.1)
        stream.open()

        let arrived = recorder.expectChunks(1, test: self)
        let start = DispatchTime.now().uptimeNanoseconds
        stream.write(bytes(0x01))
        wait(for: [arrived], timeout: SimulatedByteStreamTests.timeout)

        XCTAssertEqual(recorder.chunks, [reply])
        let elapsed = Double(recorder.chunkTimes[0] - start) / 1_000_000_000
        XCTAssertGreaterThanOrEqual(elapsed, 0.1)
        XCTAssertTrue(recorder.allChunksArrivedOnTheExpectedQueue)
        XCTAssertFalse(recorder.anyChunkArrivedOnMain)
    }

    func testAStreamGivenNoQueueMakesItsOwnAndDeliversOffTheMainThread() {
        let device = TableDevice(table: [bytes(0x01): bytes(0x02)])
        let stream = SimulatedByteStream(device: device, replyLatency: 0)
        let recorder = StreamRecorder()
        stream.delegate = recorder
        stream.open()

        let arrived = recorder.expectChunks(1, test: self)
        stream.write(bytes(0x01))
        wait(for: [arrived], timeout: SimulatedByteStreamTests.timeout)

        XCTAssertEqual(recorder.chunks, [bytes(0x02)])
        XCTAssertFalse(recorder.anyChunkArrivedOnMain)
    }

    func testTheDefaultsAreOneMillisecondOfLatencyNoFillerAndFF() {
        let stream = SimulatedByteStream(device: TableDevice())

        XCTAssertEqual(stream.name, "simulated")
        XCTAssertEqual(stream.replyLatency, 0.001)
        XCTAssertEqual(stream.fillerByteCount, 0)
        XCTAssertEqual(stream.fillerByte, 0xFF)
        XCTAssertFalse(stream.isOpen)
        XCTAssertFalse(stream.isDropArmed)
    }

    func testAWriteTheDeviceDoesNotAnswerDeliversNothing() {
        let device = TableDevice(table: [bytes(0x02): bytes(0xAA)])
        let (stream, recorder) = self.makeStream(device)
        stream.open()

        // The unanswered frame goes first: had it produced a chunk, the chunk would be seen before the
        // answer to the second one.
        let arrived = recorder.expectChunks(1, test: self)
        stream.write(bytes(0x01))
        stream.write(bytes(0x02))
        wait(for: [arrived], timeout: SimulatedByteStreamTests.timeout)
        self.drainQueue()

        XCTAssertEqual(recorder.chunks, [bytes(0xAA)])
        XCTAssertEqual(device.frames, [bytes(0x01), bytes(0x02)])
    }

    func testTheDeviceIsCalledOnceForEachWriteInOrderWithTheExactBytes() {
        let frames = [
            bytes(0x00),
            bytes(0xFF, 0x00, 0xFF),
            bytes(0x7E, 0x01, 0x02, 0x03, 0x7E),
            bytes(0x10),
            bytes(0x00, 0x00)
        ]
        let device = TableDevice(table: Dictionary(uniqueKeysWithValues: frames.map { ($0, $0) }))
        let (stream, recorder) = self.makeStream(device)
        stream.open()

        let arrived = recorder.expectChunks(frames.count, test: self)
        for frame in frames {
            stream.write(frame)
        }
        wait(for: [arrived], timeout: SimulatedByteStreamTests.timeout)

        XCTAssertEqual(device.frames, frames)
        XCTAssertEqual(recorder.chunks, frames)
    }

    func testTheDeviceIsCalledOnTheStreamQueue() {
        final class QueueCheckingDevice: SerialDeviceSimulator {
            let key: DispatchSpecificKey<UInt8>
            let onQueue: XCTestExpectation
            init(key: DispatchSpecificKey<UInt8>, onQueue: XCTestExpectation) {
                self.key = key
                self.onQueue = onQueue
            }

            func reply(to frame: Data) -> Data? {
                if DispatchQueue.getSpecific(key: self.key) != nil {
                    self.onQueue.fulfill()
                }
                return nil
            }
        }

        let onQueue = expectation(description: "device called on the stream queue")
        let device = QueueCheckingDevice(key: self.queueKey, onQueue: onQueue)
        let (stream, _) = self.makeStream(device)
        stream.open()

        stream.write(bytes(0x01))
        wait(for: [onQueue], timeout: SimulatedByteStreamTests.timeout)
    }

    func testRepliesToSeveralWritesKeepTheirOrder() {
        let count = 40
        var table: [Data: Data] = [:]
        var frames: [Data] = []
        for index in 0..<count {
            let frame = bytes(0x01, UInt8(index))
            frames.append(frame)
            table[frame] = bytes(0x02, UInt8(index))
        }
        let device = TableDevice(table: table)
        let (stream, recorder) = self.makeStream(device, latency: 0.01)
        stream.open()

        let arrived = recorder.expectChunks(count, test: self)
        for frame in frames {
            stream.write(frame)
        }
        wait(for: [arrived], timeout: SimulatedByteStreamTests.timeout)

        XCTAssertEqual(recorder.chunks, frames.map { bytes(0x02, $0[1]) })
    }

    func testALaterReplyNeverOvertakesAnEarlierSlowerOne() {
        let device = TableDevice(table: [bytes(0x01): bytes(0xA1), bytes(0x02): bytes(0xB2)])
        let (stream, recorder) = self.makeStream(device, latency: 0.15)
        stream.open()

        stream.write(bytes(0x01))
        self.drainQueue()
        stream.replyLatency = 0

        let arrived = recorder.expectChunks(2, test: self)
        stream.write(bytes(0x02))
        wait(for: [arrived], timeout: SimulatedByteStreamTests.timeout)

        XCTAssertEqual(recorder.chunks, [bytes(0xA1), bytes(0xB2)])
    }

    func testTheLatencyAppliesToLaterWrites() {
        let device = TableDevice(table: [bytes(0x01): bytes(0xA1)])
        let (stream, recorder) = self.makeStream(device, latency: 0)
        stream.open()
        stream.replyLatency = 0.15
        XCTAssertEqual(stream.replyLatency, 0.15)

        let arrived = recorder.expectChunks(1, test: self)
        let start = DispatchTime.now().uptimeNanoseconds
        stream.write(bytes(0x01))
        wait(for: [arrived], timeout: SimulatedByteStreamTests.timeout)

        let elapsed = Double(recorder.chunkTimes[0] - start) / 1_000_000_000
        XCTAssertGreaterThanOrEqual(elapsed, 0.15)
    }

    // MARK: - Filler bytes

    func testFillerBytesAreInFrontOfTheReplyInTheSameChunk() {
        let device = TableDevice(table: [bytes(0x01): bytes(0x10, 0x20)])
        let (stream, recorder) = self.makeStream(device)
        stream.fillerByteCount = 3
        stream.fillerByte = 0x55
        stream.open()

        let arrived = recorder.expectChunks(1, test: self)
        stream.write(bytes(0x01))
        wait(for: [arrived], timeout: SimulatedByteStreamTests.timeout)
        self.drainQueue()

        XCTAssertEqual(recorder.chunks, [bytes(0x55, 0x55, 0x55, 0x10, 0x20)])
    }

    func testFillerBytesDefaultToFF() {
        let device = TableDevice(table: [bytes(0x01): bytes(0x10)])
        let (stream, recorder) = self.makeStream(device)
        stream.fillerByteCount = 2
        stream.open()

        let arrived = recorder.expectChunks(1, test: self)
        stream.write(bytes(0x01))
        wait(for: [arrived], timeout: SimulatedByteStreamTests.timeout)

        XCTAssertEqual(recorder.chunks, [bytes(0xFF, 0xFF, 0x10)])
    }

    func testANegativeFillerCountMeansNoFiller() {
        let device = TableDevice(table: [bytes(0x01): bytes(0x10)])
        let (stream, recorder) = self.makeStream(device)
        stream.fillerByteCount = -5
        XCTAssertEqual(stream.fillerByteCount, 0)
        stream.open()

        let arrived = recorder.expectChunks(1, test: self)
        stream.write(bytes(0x01))
        wait(for: [arrived], timeout: SimulatedByteStreamTests.timeout)

        XCTAssertEqual(recorder.chunks, [bytes(0x10)])
    }

    func testFillerSettingsApplyToLaterWritesOnly() {
        let device = TableDevice(table: [bytes(0x01): bytes(0x10)])
        let (stream, recorder) = self.makeStream(device)
        stream.open()

        stream.write(bytes(0x01))
        self.drainQueue()
        stream.fillerByteCount = 1
        stream.fillerByte = 0x00

        let arrived = recorder.expectChunks(2, test: self)
        stream.write(bytes(0x01))
        wait(for: [arrived], timeout: SimulatedByteStreamTests.timeout)

        XCTAssertEqual(recorder.chunks, [bytes(0x10), bytes(0x00, 0x10)])
    }

    // MARK: - Dropped replies

    func testDropNextReplyDropsExactlyTheNextReply() {
        let device = TableDevice(table: [bytes(0x01): bytes(0xA1), bytes(0x02): bytes(0xB2)])
        let (stream, recorder) = self.makeStream(device)
        stream.open()

        XCTAssertFalse(stream.isDropArmed)
        stream.dropNextReply()
        XCTAssertTrue(stream.isDropArmed)

        let arrived = recorder.expectChunks(1, test: self)
        stream.write(bytes(0x01))
        stream.write(bytes(0x02))
        wait(for: [arrived], timeout: SimulatedByteStreamTests.timeout)
        self.drainQueue()

        XCTAssertEqual(recorder.chunks, [bytes(0xB2)])
        XCTAssertEqual(device.frames, [bytes(0x01), bytes(0x02)])
        XCTAssertFalse(stream.isDropArmed)
    }

    func testAWriteTheDeviceDoesNotAnswerDoesNotUseUpTheDrop() {
        let device = TableDevice(table: [bytes(0x02): bytes(0xB2), bytes(0x03): bytes(0xC3)])
        let (stream, recorder) = self.makeStream(device)
        stream.open()
        stream.dropNextReply()

        stream.write(bytes(0x01))
        self.drainQueue()
        XCTAssertEqual(device.frames, [bytes(0x01)])
        XCTAssertTrue(stream.isDropArmed)

        let arrived = recorder.expectChunks(1, test: self)
        stream.write(bytes(0x02))
        stream.write(bytes(0x03))
        wait(for: [arrived], timeout: SimulatedByteStreamTests.timeout)
        self.drainQueue()

        XCTAssertEqual(recorder.chunks, [bytes(0xC3)])
        XCTAssertFalse(stream.isDropArmed)
    }

    // MARK: - Open, close and removal

    func testOpeningAndClosingReportOnceEvenWhenRepeated() {
        let (stream, recorder) = self.makeStream(TableDevice())

        XCTAssertFalse(stream.isOpen)
        stream.close()
        stream.simulateRemoval()
        XCTAssertEqual(recorder.events, [])

        stream.open()
        stream.open()
        XCTAssertTrue(stream.isOpen)
        XCTAssertEqual(recorder.events, [.opened])

        stream.close()
        stream.close()
        stream.simulateRemoval()
        XCTAssertFalse(stream.isOpen)
        XCTAssertEqual(recorder.events, [.opened, .closed(.requested)])
    }

    func testCloseReportsRequestedBeforeItReturns() {
        let (stream, recorder) = self.makeStream(TableDevice())
        stream.open()
        XCTAssertEqual(recorder.events, [.opened])

        stream.close()

        XCTAssertEqual(recorder.events, [.opened, .closed(.requested)])
    }

    func testSimulateRemovalReportsRemovedBeforeItReturns() {
        let (stream, recorder) = self.makeStream(TableDevice())
        stream.open()

        stream.simulateRemoval()

        XCTAssertFalse(stream.isOpen)
        XCTAssertEqual(recorder.events, [.opened, .closed(.removed)])
    }

    func testARemovalLosesTheReplyOnItsWay() {
        let device = TableDevice(table: [bytes(0x01): bytes(0xA1)])
        let (stream, recorder) = self.makeStream(device, latency: 0.2)
        stream.open()

        let asked = expectation(description: "the device was asked")
        device.observeFrames { _ in asked.fulfill() }
        stream.write(bytes(0x01))
        wait(for: [asked], timeout: SimulatedByteStreamTests.timeout)

        stream.simulateRemoval()
        XCTAssertEqual(recorder.events, [.opened, .closed(.removed)])

        let nothing = recorder.expectNoChunk(test: self)
        wait(for: [nothing], timeout: 0.5)
        XCTAssertEqual(recorder.chunks, [])
    }

    func testARemovalLosesTheReplyOnItsWayEvenWhenItComesBeforeTheDeviceIsAsked() {
        let device = TableDevice(table: [bytes(0x01): bytes(0xA1)])
        let (stream, recorder) = self.makeStream(device, latency: 0.2)
        stream.open()

        stream.write(bytes(0x01))
        stream.simulateRemoval()

        let nothing = recorder.expectNoChunk(test: self)
        wait(for: [nothing], timeout: 0.5)
        XCTAssertEqual(recorder.chunks, [])
        XCTAssertEqual(recorder.events.last, .closed(.removed))
    }

    func testCloseLosesTheReplyOnItsWay() {
        let device = TableDevice(table: [bytes(0x01): bytes(0xA1)])
        let (stream, recorder) = self.makeStream(device, latency: 0.2)
        stream.open()

        stream.write(bytes(0x01))
        self.drainQueue()
        stream.close()

        let nothing = recorder.expectNoChunk(test: self)
        wait(for: [nothing], timeout: 0.5)
        XCTAssertEqual(recorder.chunks, [])
    }

    func testAReplyFromBeforeARemovalDoesNotReachTheStreamOpenedAgain() {
        let device = TableDevice(table: [bytes(0x01): bytes(0xA1), bytes(0x02): bytes(0xB2)])
        let (stream, recorder) = self.makeStream(device, latency: 0.2)
        stream.open()

        stream.write(bytes(0x01))
        self.drainQueue()
        stream.simulateRemoval()
        stream.replyLatency = 0
        stream.open()

        let arrived = recorder.expectChunks(1, test: self)
        stream.write(bytes(0x02))
        wait(for: [arrived], timeout: SimulatedByteStreamTests.timeout)

        let nothingMore = recorder.expectNoChunk(test: self)
        wait(for: [nothingMore], timeout: 0.5)
        XCTAssertEqual(recorder.chunks, [bytes(0xB2)])
    }

    func testOpenAfterRemovalWorksAgain() {
        let device = TableDevice(table: [bytes(0x01): bytes(0xA1)])
        let (stream, recorder) = self.makeStream(device)
        stream.open()
        stream.simulateRemoval()
        stream.open()

        XCTAssertTrue(stream.isOpen)
        XCTAssertEqual(recorder.events, [.opened, .closed(.removed), .opened])

        let arrived = recorder.expectChunks(1, test: self)
        stream.write(bytes(0x01))
        wait(for: [arrived], timeout: SimulatedByteStreamTests.timeout)

        XCTAssertEqual(recorder.chunks, [bytes(0xA1)])
    }

    func testWritesToAStreamThatWasNeverOpenedDoNotReachTheDevice() {
        let device = TableDevice(table: [bytes(0x01): bytes(0xA1), bytes(0x02): bytes(0xB2)])
        let (stream, recorder) = self.makeStream(device)

        stream.write(bytes(0x01))
        self.drainQueue()
        stream.open()

        let arrived = recorder.expectChunks(1, test: self)
        stream.write(bytes(0x02))
        wait(for: [arrived], timeout: SimulatedByteStreamTests.timeout)

        XCTAssertEqual(device.frames, [bytes(0x02)])
        XCTAssertEqual(recorder.chunks, [bytes(0xB2)])
    }

    func testWritesToAClosedStreamDoNotReachTheDevice() {
        let device = TableDevice(table: [bytes(0x01): bytes(0xA1), bytes(0x02): bytes(0xB2)])
        let (stream, recorder) = self.makeStream(device)
        stream.open()
        stream.close()

        stream.write(bytes(0x01))
        self.drainQueue()
        stream.open()

        let arrived = recorder.expectChunks(1, test: self)
        stream.write(bytes(0x02))
        wait(for: [arrived], timeout: SimulatedByteStreamTests.timeout)

        XCTAssertEqual(device.frames, [bytes(0x02)])
        XCTAssertEqual(recorder.chunks, [bytes(0xB2)])
    }

    func testWritesAfterARemovalDoNotReachTheDevice() {
        let device = TableDevice(table: [bytes(0x01): bytes(0xA1)])
        let (stream, recorder) = self.makeStream(device)
        stream.open()
        stream.simulateRemoval()

        stream.write(bytes(0x01))
        self.drainQueue()

        XCTAssertEqual(device.frames, [])
        XCTAssertEqual(recorder.chunks, [])
    }

    func testWriteReturnsBeforeTheDeviceIsAskedOrAnythingIsReported() {
        // Hold the stream's queue busy: `write` must still return at once, and neither the device nor the
        // delegate may be called until the queue is free again.
        let device = TableDevice(table: [bytes(0x01): bytes(0xA1)])
        let (stream, recorder) = self.makeStream(device, latency: 0)
        stream.open()

        let started = expectation(description: "queue held")
        let release = DispatchSemaphore(value: 0)
        self.queue.async {
            started.fulfill()
            release.wait()
        }
        wait(for: [started], timeout: SimulatedByteStreamTests.timeout)

        stream.write(bytes(0x01))
        XCTAssertEqual(recorder.chunks, [])
        XCTAssertEqual(device.frames, [])

        let arrived = recorder.expectChunks(1, test: self)
        release.signal()
        wait(for: [arrived], timeout: SimulatedByteStreamTests.timeout)
        XCTAssertEqual(recorder.chunks, [bytes(0xA1)])
    }
}
