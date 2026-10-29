//
//  PosixSerialPortTests.swift
//  SerialPortSwiftTests
//

import Foundation
import SerialPortSwift
import SerialPortSwiftSimulation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Records what a port tells its delegate, from whichever thread it says it.
private final class PortEventRecorder: SerialByteStreamDelegate {
    private let lock = NSLock()
    private var openThreads: [Thread] = []
    private var closeReasons: [SerialCloseReason] = []
    private var closeWasOnPortQueue: [Bool] = []
    private var closeThreads: [Thread] = []
    private var receivedChunks: [Data] = []
    private var receivedBytes = Data()
    private var chunksOffPortQueue = 0
    private var byteWaiters: [(count: Int, expectation: XCTestExpectation)] = []
    private var closeWaiters: [(count: Int, expectation: XCTestExpectation)] = []

    /// Whether the calling code runs on the queue the port reports on. Set before the port opens.
    var isOnPortQueue: () -> Bool = { return true }
    /// Called, on the port's queue, for every chunk the port delivers.
    var onReceive: ((Data) -> Void)?

    var openCount: Int {
        return self.locked { self.openThreads.count }
    }

    var lastOpenThread: Thread? {
        return self.locked { self.openThreads.last }
    }

    var closes: [SerialCloseReason] {
        return self.locked { self.closeReasons }
    }

    var lastCloseThread: Thread? {
        return self.locked { self.closeThreads.last }
    }

    var closesOnPortQueue: [Bool] {
        return self.locked { self.closeWasOnPortQueue }
    }

    var received: Data {
        return self.locked { self.receivedBytes }
    }

    var chunks: [Data] {
        return self.locked { self.receivedChunks }
    }

    var chunksReportedOffPortQueue: Int {
        return self.locked { self.chunksOffPortQueue }
    }

    private func locked<T>(_ work: () -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return work()
    }

    /// Fulfilled once at least `count` bytes arrived in total.
    func expectBytes(_ count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "received \(count) bytes")
        let alreadyThere: Bool = self.locked {
            if self.receivedBytes.count >= count {
                return true
            }
            self.byteWaiters.append((count: count, expectation: expectation))
            return false
        }
        if alreadyThere {
            expectation.fulfill()
        }
        return expectation
    }

    /// Fulfilled once the port reported `count` closes in total.
    func expectCloses(_ count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "\(count) closes")
        let alreadyThere: Bool = self.locked {
            if self.closeReasons.count >= count {
                return true
            }
            self.closeWaiters.append((count: count, expectation: expectation))
            return false
        }
        if alreadyThere {
            expectation.fulfill()
        }
        return expectation
    }

    func streamDidOpen(_ stream: SerialByteStream) {
        self.locked { self.openThreads.append(Thread.current) }
    }

    func stream(_ stream: SerialByteStream, didReceive bytes: Data) {
        let onPortQueue = self.isOnPortQueue()
        let ready: [XCTestExpectation] = self.locked {
            self.receivedChunks.append(bytes)
            self.receivedBytes.append(bytes)
            if !onPortQueue {
                self.chunksOffPortQueue += 1
            }
            let total = self.receivedBytes.count
            let done = self.byteWaiters.filter { $0.count <= total }
            self.byteWaiters = self.byteWaiters.filter { $0.count > total }
            return done.map { $0.expectation }
        }
        ready.forEach { $0.fulfill() }
        self.onReceive?(bytes)
    }

    func streamDidClose(_ stream: SerialByteStream, reason: SerialCloseReason) {
        let onPortQueue = self.isOnPortQueue()
        let ready: [XCTestExpectation] = self.locked {
            self.closeReasons.append(reason)
            self.closeWasOnPortQueue.append(onPortQueue)
            self.closeThreads.append(Thread.current)
            let total = self.closeReasons.count
            let done = self.closeWaiters.filter { $0.count <= total }
            self.closeWaiters = self.closeWaiters.filter { $0.count > total }
            return done.map { $0.expectation }
        }
        ready.forEach { $0.fulfill() }
    }
}

private func openDeviceSide(_ path: String) -> Int32 {
    return open(path, O_RDWR | O_NOCTTY)
}

private func closeDescriptor(_ descriptor: Int32) {
    _ = close(descriptor)
}

private func lineSettings(of descriptor: Int32) -> termios {
    var settings = termios()
    XCTAssertEqual(tcgetattr(descriptor, &settings), 0, "tcgetattr failed: errno \(errno)")
    return settings
}

private func isSet(_ flag: Int32, in flags: tcflag_t) -> Bool {
    return flags & tcflag_t(flag) != 0
}

final class PosixSerialPortTests: XCTestCase {
    private var terminals: [PseudoTerminal] = []
    private var ports: [PosixSerialPort] = []
    private var recorders: [PortEventRecorder] = []
    private var descriptors: [Int32] = []

    override func tearDown() {
        self.ports.forEach { $0.close() }
        self.ports = []
        self.recorders = []
        self.descriptors.forEach { closeDescriptor($0) }
        self.descriptors = []
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

    private func makePort(
        on terminal: PseudoTerminal,
        configuration: SerialPortConfiguration = SerialPortConfiguration(),
        queue: DispatchQueue? = nil
    ) -> (port: PosixSerialPort, recorder: PortEventRecorder) {
        let port = PosixSerialPort(path: terminal.devicePath, configuration: configuration, queue: queue)
        let recorder = PortEventRecorder()
        port.delegate = recorder
        self.ports.append(port)
        self.recorders.append(recorder)
        return (port, recorder)
    }

    /// Opens a second descriptor on the device side, as a bystander that reads the line settings.
    private func makeObserver(on terminal: PseudoTerminal) -> Int32 {
        let descriptor = openDeviceSide(terminal.devicePath)
        XCTAssertGreaterThanOrEqual(descriptor, 0, "could not open \(terminal.devicePath): errno \(errno)")
        if descriptor >= 0 {
            self.descriptors.append(descriptor)
        }
        return descriptor
    }

    // MARK: Open

    func testOpeningReportsTheOpenBeforeItReturns() throws {
        let terminal = try self.makeTerminal()
        let (port, recorder) = self.makePort(on: terminal)
        XCTAssertFalse(port.isOpen)

        port.open()

        XCTAssertEqual(recorder.openCount, 1)
        XCTAssertTrue(recorder.lastOpenThread === Thread.current)
        XCTAssertTrue(port.isOpen)
        XCTAssertEqual(recorder.closes, [])
    }

    func testOpeningAnOpenPortDoesNothing() throws {
        let terminal = try self.makeTerminal()
        let (port, recorder) = self.makePort(on: terminal)
        port.open()

        port.open()

        XCTAssertEqual(recorder.openCount, 1)
        XCTAssertTrue(port.isOpen)
        XCTAssertEqual(recorder.closes, [])
    }

    func testOpeningAMissingPathFails() {
        let path = "/dev/serial-port-swift-does-not-exist"
        let port = PosixSerialPort(path: path)
        let recorder = PortEventRecorder()
        port.delegate = recorder

        port.open()

        XCTAssertEqual(recorder.openCount, 0)
        XCTAssertEqual(recorder.closes, [.failed(.openFailed(path: path, code: ENOENT))])
        XCTAssertFalse(port.isOpen)
    }

    func testThePortTakesTheNameAndPathOfADescriptor() {
        let descriptor = SerialPortDescriptor(
            name: "usbserial-1420",
            calloutPath: "/dev/cu.usbserial-1420",
            dialinPath: "/dev/tty.usbserial-1420"
        )

        let port = PosixSerialPort(descriptor: descriptor)

        XCTAssertEqual(port.path, "/dev/cu.usbserial-1420")
        XCTAssertEqual(port.name, "usbserial-1420")
    }

    func testTheNameDefaultsToTheDefaultNameOfThePath() {
        XCTAssertEqual(PosixSerialPort(path: "/dev/ttyUSB0").name, "ttyUSB0")
        XCTAssertEqual(PosixSerialPort(path: "/dev/ttyUSB0", name: "bench").name, "bench")
    }

    func testDefaultNameStripsALeadingCalloutOrDialinPrefix() {
        XCTAssertEqual(PosixSerialPort.defaultName(forPath: "/dev/cu.usbserial-1420"), "usbserial-1420")
        XCTAssertEqual(PosixSerialPort.defaultName(forPath: "/dev/tty.usbmodem14101"), "usbmodem14101")
        XCTAssertEqual(PosixSerialPort.defaultName(forPath: "/dev/ttyUSB0"), "ttyUSB0")
        XCTAssertEqual(PosixSerialPort.defaultName(forPath: "/dev/ttyACM1"), "ttyACM1")
        XCTAssertEqual(PosixSerialPort.defaultName(forPath: "/dev/pts/3"), "3")
        XCTAssertEqual(PosixSerialPort.defaultName(forPath: "/dev/ttys004"), "ttys004")
        XCTAssertEqual(PosixSerialPort.defaultName(forPath: "ttyS0"), "ttyS0")
        XCTAssertEqual(PosixSerialPort.defaultName(forPath: "/dev/cu.cu.x"), "cu.x")
    }

    func testDefaultNameKeepsAComponentThatIsOnlyAPrefix() {
        XCTAssertEqual(PosixSerialPort.defaultName(forPath: "/dev/cu."), "cu.")
        XCTAssertEqual(PosixSerialPort.defaultName(forPath: "/"), "/")
    }

    // MARK: Reading and writing

    func testBytesFromThePeerArriveUnchanged() throws {
        let terminal = try self.makeTerminal()
        let (port, recorder) = self.makePort(on: terminal)
        port.open()
        // Every byte a cooked terminal would eat, translate or act on.
        let payload = Data([0xFF, 0x00, 0x0D, 0x0A, 0x03, 0x7F, 0x04, 0x08, 0x11, 0x13, 0x15, 0x1A, 0x1C, 0x41])
        let arrived = recorder.expectBytes(payload.count)

        try terminal.write(payload)

        self.wait(for: [arrived], timeout: 15)
        XCTAssertEqual(recorder.received, payload)
        XCTAssertTrue(port.isOpen)
    }

    func testBytesWrittenByThePortReachThePeerUnchanged() throws {
        let terminal = try self.makeTerminal()
        let (port, _) = self.makePort(on: terminal)
        port.open()
        let payload = Data([0x0A, 0x41, 0x0D, 0x0A, 0xFF, 0x00, 0x03, 0x7F, 0x0A])

        port.write(payload)

        XCTAssertEqual(terminal.read(count: payload.count, timeout: 15), payload)
        // A newline turned into carriage return and newline would leave extra bytes behind.
        XCTAssertEqual(terminal.read(timeout: 0.2), Data())
    }

    func testAReplyThatArrivesInTwoWritesReachesTheDelegateInOrder() throws {
        let terminal = try self.makeTerminal()
        let (port, recorder) = self.makePort(on: terminal)
        port.open()
        let arrived = recorder.expectBytes(4)

        try terminal.write(Data("AB".utf8))
        Thread.sleep(forTimeInterval: 0.05)
        try terminal.write(Data("CD".utf8))

        self.wait(for: [arrived], timeout: 15)
        XCTAssertEqual(recorder.received, Data("ABCD".utf8))
        XCTAssertEqual(Data(recorder.chunks.joined()), Data("ABCD".utf8))
    }

    func testReceivedBytesAreReportedOnThePortsQueue() throws {
        let terminal = try self.makeTerminal()
        let queue = DispatchQueue(label: "PosixSerialPortTests.port")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        let (port, recorder) = self.makePort(on: terminal, queue: queue)
        recorder.isOnPortQueue = { return DispatchQueue.getSpecific(key: key) == true }
        port.open()
        let arrived = recorder.expectBytes(3)

        try terminal.write(Data([0x01, 0x02, 0x03]))

        self.wait(for: [arrived], timeout: 15)
        XCTAssertFalse(recorder.chunks.isEmpty)
        XCTAssertEqual(recorder.chunksReportedOffPortQueue, 0)
    }

    func testWritesReachThePeerInTheOrderTheyWereGiven() throws {
        let terminal = try self.makeTerminal()
        let (port, _) = self.makePort(on: terminal)
        port.open()

        port.write(Data("first ".utf8))
        port.write(Data("second ".utf8))
        port.write(Data("third".utf8))

        XCTAssertEqual(terminal.read(count: 18, timeout: 15), Data("first second third".utf8))
    }

    func testALargeWriteIsWrittenInFull() throws {
        let terminal = try self.makeTerminal()
        let (port, _) = self.makePort(on: terminal)
        port.open()
        let payload = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 7) })

        port.write(payload)

        XCTAssertEqual(terminal.read(count: payload.count, timeout: 30), payload)
    }

    func testWritingNothingDoesNothing() throws {
        let terminal = try self.makeTerminal()
        let (port, recorder) = self.makePort(on: terminal)
        port.open()

        port.write(Data())

        XCTAssertEqual(terminal.read(timeout: 0.2), Data())
        XCTAssertTrue(port.isOpen)
        XCTAssertEqual(recorder.closes, [])
    }

    func testWritingToAClosedPortDoesNothing() throws {
        let terminal = try self.makeTerminal()
        _ = self.makeObserver(on: terminal)
        let (neverOpened, _) = self.makePort(on: terminal)
        let (reopened, _) = self.makePort(on: terminal)
        reopened.open()
        reopened.close()

        neverOpened.write(Data([0x01, 0x02]))
        reopened.write(Data([0x03, 0x04]))

        // Both writes are queued ahead of this call.
        XCTAssertFalse(reopened.isOpen)
        XCTAssertFalse(neverOpened.isOpen)
        XCTAssertEqual(terminal.read(timeout: 0.3), Data())
    }

    func testWritingToAHungUpPeerClosesThePortOnce() throws {
        let terminal = try self.makeTerminal()
        let (port, recorder) = self.makePort(on: terminal)
        port.open()
        let closed = recorder.expectCloses(1)
        terminal.close()

        port.write(Data(repeating: 0x55, count: 100))

        self.wait(for: [closed], timeout: 15)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(recorder.closes.count, 1)
        switch recorder.closes.first {
        case .some(.removed), .some(.failed(.writeFailed)):
            break
        default:
            XCTFail("unexpected close: \(String(describing: recorder.closes.first))")
        }
        XCTAssertFalse(port.isOpen)
    }

    // MARK: Exclusive access

    func testASecondOpenerIsRefusedWhileThePortIsExclusive() throws {
        let terminal = try self.makeTerminal()
        let (first, firstRecorder) = self.makePort(on: terminal)
        let (second, secondRecorder) = self.makePort(on: terminal)
        first.open()

        second.open()

        XCTAssertEqual(secondRecorder.closes, [.failed(.exclusiveAccessDenied(path: terminal.devicePath))])
        XCTAssertEqual(secondRecorder.openCount, 0)
        XCTAssertFalse(second.isOpen)
        // The first port is untouched.
        XCTAssertTrue(first.isOpen)
        XCTAssertEqual(firstRecorder.closes, [])
        let arrived = firstRecorder.expectBytes(1)
        try terminal.write(Data([0x42]))
        self.wait(for: [arrived], timeout: 15)
    }

    func testTwoPortsOpenTogetherWithoutExclusiveAccess() throws {
        let terminal = try self.makeTerminal()
        let shared = SerialPortConfiguration(exclusiveAccess: false)
        let (first, firstRecorder) = self.makePort(on: terminal, configuration: shared)
        let (second, secondRecorder) = self.makePort(on: terminal, configuration: shared)

        first.open()
        second.open()

        XCTAssertTrue(first.isOpen)
        XCTAssertTrue(second.isOpen)
        XCTAssertEqual(firstRecorder.closes, [])
        XCTAssertEqual(secondRecorder.closes, [])
    }

    // MARK: Close

    func testClosingReportsTheCloseBeforeItReturns() throws {
        let terminal = try self.makeTerminal()
        let (port, recorder) = self.makePort(on: terminal)
        port.open()

        port.close()

        XCTAssertEqual(recorder.closes, [.requested])
        XCTAssertTrue(recorder.lastCloseThread === Thread.current)
        XCTAssertFalse(port.isOpen)
    }

    func testClosingAClosedPortReportsNothing() throws {
        let terminal = try self.makeTerminal()
        let (port, recorder) = self.makePort(on: terminal)

        port.close()
        port.open()
        port.close()
        port.close()

        XCTAssertEqual(recorder.closes, [.requested])
        XCTAssertEqual(recorder.openCount, 1)
    }

    func testThePathCanBeOpenedAgainAsSoonAsCloseReturns() throws {
        let terminal = try self.makeTerminal()
        let (port, recorder) = self.makePort(on: terminal)

        for _ in 0..<5 {
            port.open()
            XCTAssertTrue(port.isOpen)
            port.close()
            XCTAssertFalse(port.isOpen)
        }

        XCTAssertEqual(recorder.openCount, 5)
        XCTAssertEqual(recorder.closes, Array(repeating: .requested, count: 5))
    }

    func testAnotherPortCanOpenThePathRightAfterCloseReturns() throws {
        let terminal = try self.makeTerminal()
        let (first, _) = self.makePort(on: terminal)
        let (second, secondRecorder) = self.makePort(on: terminal)
        first.open()
        first.close()

        second.open()

        XCTAssertTrue(second.isOpen)
        XCTAssertEqual(secondRecorder.closes, [])
    }

    func testAReopenedPortReadsAgain() throws {
        let terminal = try self.makeTerminal()
        let (port, recorder) = self.makePort(on: terminal)
        port.open()
        port.close()
        port.open()
        let arrived = recorder.expectBytes(2)

        try terminal.write(Data([0x10, 0x20]))

        self.wait(for: [arrived], timeout: 15)
        XCTAssertEqual(recorder.received, Data([0x10, 0x20]))
    }

    func testThePortCanBeClosedAndReopenedFromItsOwnDelegateCallback() throws {
        let terminal = try self.makeTerminal()
        let (port, recorder) = self.makePort(on: terminal)
        port.open()
        let reopened = XCTestExpectation(description: "closed and reopened from the callback")
        var handled = false
        // Only ever touched on the port's queue.
        recorder.onReceive = { _ in
            if handled {
                return
            }
            handled = true
            port.close()
            port.open()
            reopened.fulfill()
        }

        try terminal.write(Data([0x01]))

        self.wait(for: [reopened], timeout: 15)
        XCTAssertEqual(recorder.closes, [.requested])
        XCTAssertEqual(recorder.openCount, 2)
        XCTAssertTrue(port.isOpen)
        let arrived = recorder.expectBytes(2)
        try terminal.write(Data([0x02]))
        self.wait(for: [arrived], timeout: 15)
    }

    func testDroppingAnOpenPortGivesTheLineBackWithoutTellingTheDelegate() throws {
        let terminal = try self.makeTerminal()
        let observer = self.makeObserver(on: terminal)
        let recorder = PortEventRecorder()
        var port: PosixSerialPort? = PosixSerialPort(path: terminal.devicePath)
        port?.delegate = recorder
        port?.open()
        XCTAssertFalse(isSet(ICANON, in: lineSettings(of: observer).c_lflag))

        port = nil

        XCTAssertTrue(isSet(ICANON, in: lineSettings(of: observer).c_lflag))
        XCTAssertEqual(recorder.openCount, 1)
        XCTAssertEqual(recorder.closes, [])
    }

    // MARK: Line settings

    func testClosingGivesTheLineSettingsBack() throws {
        let terminal = try self.makeTerminal()
        let observer = self.makeObserver(on: terminal)
        let (port, _) = self.makePort(on: terminal)
        let before = lineSettings(of: observer)
        XCTAssertTrue(isSet(ICANON, in: before.c_lflag), "a new terminal is cooked")
        XCTAssertTrue(isSet(ECHO, in: before.c_lflag))

        port.open()
        let during = lineSettings(of: observer)
        port.close()
        let after = lineSettings(of: observer)

        XCTAssertFalse(isSet(ICANON, in: during.c_lflag))
        XCTAssertFalse(isSet(ISIG, in: during.c_lflag))
        XCTAssertFalse(isSet(ECHO, in: during.c_lflag))
        XCTAssertTrue(isSet(CLOCAL, in: during.c_cflag))
        XCTAssertTrue(isSet(CREAD, in: during.c_cflag))
        XCTAssertTrue(isSet(HUPCL, in: during.c_cflag))
        XCTAssertTrue(isSet(ICANON, in: after.c_lflag))
        XCTAssertTrue(isSet(ISIG, in: after.c_lflag))
        XCTAssertTrue(isSet(ECHO, in: after.c_lflag))
    }

    func testAReadReturnsOnceOneByteIsThere() throws {
        let terminal = try self.makeTerminal()
        let observer = self.makeObserver(on: terminal)
        let (port, _) = self.makePort(on: terminal)

        port.open()
        var settings = lineSettings(of: observer)
        let controlCharacters = withUnsafeBytes(of: &settings.c_cc) { (bytes: UnsafeRawBufferPointer) -> (UInt8, UInt8) in
            return (bytes[Int(VMIN)], bytes[Int(VTIME)])
        }

        XCTAssertEqual(controlCharacters.0, 1)
        XCTAssertEqual(controlCharacters.1, 2)
    }

    func testEchoIsOffUnlessAskedFor() throws {
        let terminal = try self.makeTerminal()
        let observer = self.makeObserver(on: terminal)
        let (quiet, _) = self.makePort(on: terminal)
        XCTAssertTrue(isSet(ECHO, in: lineSettings(of: observer).c_lflag), "a new terminal echoes")
        quiet.open()
        XCTAssertFalse(isSet(ECHO, in: lineSettings(of: observer).c_lflag))
        quiet.close()

        // Start from a line that does not echo, so only the port can have turned echo on.
        var silent = lineSettings(of: observer)
        silent.c_lflag &= ~tcflag_t(ECHO)
        XCTAssertEqual(tcsetattr(observer, TCSANOW, &silent), 0)
        let (echoing, _) = self.makePort(on: terminal, configuration: SerialPortConfiguration(echo: true))
        echoing.open()

        XCTAssertTrue(isSet(ECHO, in: lineSettings(of: observer).c_lflag))
        XCTAssertFalse(isSet(ICANON, in: lineSettings(of: observer).c_lflag))
    }

    #if os(Linux)
    func testStopBitsAndHardwareFlowControlAreApplied() throws {
        let terminal = try self.makeTerminal()
        let observer = self.makeObserver(on: terminal)
        let (plain, _) = self.makePort(on: terminal)
        plain.open()
        let plainSettings = lineSettings(of: observer)
        plain.close()
        XCTAssertFalse(isSet(CSTOPB, in: plainSettings.c_cflag))
        XCTAssertEqual(plainSettings.c_cflag & tcflag_t(CRTSCTS), 0)

        let configuration = SerialPortConfiguration(stopBits: .two, flowControl: [.rtsCts])
        let (configured, _) = self.makePort(on: terminal, configuration: configuration)
        configured.open()
        let settings = lineSettings(of: observer)

        XCTAssertTrue(isSet(CSTOPB, in: settings.c_cflag))
        XCTAssertNotEqual(settings.c_cflag & tcflag_t(CRTSCTS), 0)
    }

    func testAnUnsupportedBaudRateFailsTheOpen() throws {
        let terminal = try self.makeTerminal()
        let unsupported = SerialPortConfiguration(baudRate: 123_456)
        let (port, recorder) = self.makePort(on: terminal, configuration: unsupported)

        port.open()

        XCTAssertEqual(recorder.closes, [.failed(.unsupportedBaudRate(123_456))])
        XCTAssertEqual(recorder.openCount, 0)
        XCTAssertFalse(port.isOpen)

        // The failed open left nothing behind: the path opens with a speed the system lists.
        let (supported, supportedRecorder) = self.makePort(
            on: terminal,
            configuration: SerialPortConfiguration(baudRate: 115_200)
        )
        supported.open()
        XCTAssertTrue(supported.isOpen)
        XCTAssertEqual(supportedRecorder.closes, [])
    }

    func testTheLinuxSpeedsOpen() throws {
        let terminal = try self.makeTerminal()
        for rate in [50, 300, 1_200, 9_600, 57_600, 115_200, 230_400, 460_800, 921_600, 3_000_000, 4_000_000] {
            let (port, recorder) = self.makePort(on: terminal, configuration: SerialPortConfiguration(baudRate: rate))
            port.open()
            XCTAssertTrue(port.isOpen, "\(rate) baud did not open: \(recorder.closes)")
            port.close()
        }
    }
    #endif

    // MARK: Modem lines

    func testAPortWithoutModemLinesStillOpens() throws {
        let terminal = try self.makeTerminal()
        let (port, recorder) = self.makePort(on: terminal)

        port.open()

        XCTAssertTrue(port.isOpen)
        XCTAssertEqual(recorder.closes, [])
        if let error = port.modemLinesError {
            // A pseudo-terminal has no modem lines.
            if case .modemLinesUnavailable = error {
            } else {
                XCTFail("unexpected error: \(error)")
            }
        } else {
            // The system did drive them, low.
            if case .success(let lines) = port.readModemLines() {
                XCTAssertFalse(lines.contains(.dtr))
                XCTAssertFalse(lines.contains(.rts))
            }
        }
        switch port.readModemLines() {
        case .success:
            break
        case .failure(let error):
            if case .modemLinesUnavailable = error {
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testNoModemLinesAreDrivenWhenNoneAreAskedFor() throws {
        let terminal = try self.makeTerminal()
        let (port, _) = self.makePort(on: terminal, configuration: SerialPortConfiguration(linesAfterOpen: nil))

        port.open()

        XCTAssertTrue(port.isOpen)
        XCTAssertNil(port.modemLinesError)
    }

    func testModemLinesCannotBeUsedOnAClosedPort() throws {
        let terminal = try self.makeTerminal()
        let (port, _) = self.makePort(on: terminal)

        XCTAssertEqual(port.readModemLines(), .failure(.modemLinesUnavailable(code: EBADF)))
        XCTAssertEqual(port.setModemLines(dtr: true, rts: nil), .failure(.modemLinesUnavailable(code: EBADF)))

        port.open()
        port.close()

        XCTAssertEqual(port.readModemLines(), .failure(.modemLinesUnavailable(code: EBADF)))
    }

    func testSettingModemLinesAnswersTheLinesOrTheirAbsence() throws {
        let terminal = try self.makeTerminal()
        let (port, _) = self.makePort(on: terminal)
        port.open()

        switch port.setModemLines(dtr: true, rts: false) {
        case .success(let lines):
            XCTAssertTrue(lines.contains(.dtr))
            XCTAssertFalse(lines.contains(.rts))
        case .failure(let error):
            if case .modemLinesUnavailable = error {
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    // MARK: The peer going away

    func testThePeerHangingUpClosesThePortAsRemoved() throws {
        let terminal = try self.makeTerminal()
        let queue = DispatchQueue(label: "PosixSerialPortTests.hangup")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        let (port, recorder) = self.makePort(on: terminal, queue: queue)
        recorder.isOnPortQueue = { return DispatchQueue.getSpecific(key: key) == true }
        port.open()
        let closed = recorder.expectCloses(1)

        terminal.close()

        self.wait(for: [closed], timeout: 15)
        XCTAssertEqual(recorder.closes, [.removed])
        XCTAssertEqual(recorder.closesOnPortQueue, [true])
        XCTAssertFalse(port.isOpen)

        // Already closed: nothing more to report.
        port.close()
        XCTAssertEqual(recorder.closes, [.removed])
    }
}
