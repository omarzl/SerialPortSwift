//
//  PseudoTerminalTests.swift
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

/// Opens the device side the way a program that is not a serial port would, and makes it raw so
/// the line discipline leaves the bytes alone.
private func openRawDeviceSide(_ path: String) -> Int32 {
    let descriptor = open(path, O_RDWR | O_NOCTTY)
    if descriptor < 0 {
        return descriptor
    }
    var settings = termios()
    if tcgetattr(descriptor, &settings) == 0 {
        cfmakeraw(&settings)
        _ = tcsetattr(descriptor, TCSANOW, &settings)
    }
    return descriptor
}

private func closeDescriptor(_ descriptor: Int32) {
    _ = close(descriptor)
}

private func writeAll(_ bytes: Data, to descriptor: Int32) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            return write(descriptor, raw.baseAddress! + offset, raw.count - offset)
        }
        if written < 0 && errno == EINTR {
            continue
        }
        if written <= 0 {
            return false
        }
        offset += written
    }
    return true
}

/// Reads from `descriptor` until `count` bytes arrived, the other end hung up, or `timeout` passed.
private func readBytes(from descriptor: Int32, count: Int, timeout: TimeInterval) -> Data {
    var collected = Data()
    let deadline = Date().addingTimeInterval(timeout)
    while collected.count < count {
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            break
        }
        var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&request, nfds_t(1), Int32(min(remaining * 1000, 1000)))
        if ready < 0 && errno == EINTR {
            continue
        }
        if ready <= 0 {
            continue
        }
        var buffer = [UInt8](repeating: 0, count: min(4096, count - collected.count))
        let received = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
            return read(descriptor, raw.baseAddress, raw.count)
        }
        if received > 0 {
            collected.append(contentsOf: buffer[0..<received])
        } else if received == 0 || errno != EINTR {
            break
        }
    }
    return collected
}

/// Where a background reader leaves what it read. The test reads it only after the reader is done.
private final class ReadResult {
    var bytes = Data()
}

final class PseudoTerminalTests: XCTestCase {
    private var descriptors: [Int32] = []
    private var terminals: [PseudoTerminal] = []

    override func tearDown() {
        self.descriptors.forEach { closeDescriptor($0) }
        self.descriptors = []
        self.terminals.forEach { $0.close() }
        self.terminals = []
        super.tearDown()
    }

    private func makeTerminal() throws -> PseudoTerminal {
        let terminal = try PseudoTerminal()
        self.terminals.append(terminal)
        return terminal
    }

    private func openDeviceSide(of terminal: PseudoTerminal) -> Int32 {
        let descriptor = openRawDeviceSide(terminal.devicePath)
        XCTAssertGreaterThanOrEqual(descriptor, 0, "could not open \(terminal.devicePath)")
        if descriptor >= 0 {
            self.descriptors.append(descriptor)
        }
        return descriptor
    }

    func testTheDevicePathExists() throws {
        let terminal = try self.makeTerminal()

        XCTAssertFalse(terminal.devicePath.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: terminal.devicePath))
    }

    func testTheDevicePathNamesAnUnlockedTerminalDevice() throws {
        let terminal = try self.makeTerminal()

        #if os(Linux)
        let prefix = "/dev/pts/"
        XCTAssertTrue(terminal.devicePath.hasPrefix(prefix), terminal.devicePath)
        XCTAssertNotNil(Int(terminal.devicePath.dropFirst(prefix.count)), terminal.devicePath)
        #else
        XCTAssertTrue(terminal.devicePath.hasPrefix("/dev/tty"), terminal.devicePath)
        #endif
        // A locked device side would refuse to open.
        let deviceSide = self.openDeviceSide(of: terminal)
        XCTAssertGreaterThanOrEqual(deviceSide, 0)
        XCTAssertEqual(isatty(deviceSide), 1)
    }

    func testEveryTerminalHasItsOwnDevice() throws {
        let first = try self.makeTerminal()
        let second = try self.makeTerminal()

        XCTAssertNotEqual(first.devicePath, second.devicePath)
    }

    func testWhatTheTerminalWritesReachesTheDeviceSide() throws {
        let terminal = try self.makeTerminal()
        let deviceSide = self.openDeviceSide(of: terminal)
        let payload = Data([0x41, 0x0A, 0xFF, 0x00, 0x0D, 0x03])

        try terminal.write(payload)

        XCTAssertEqual(readBytes(from: deviceSide, count: payload.count, timeout: 10), payload)
    }

    func testAnEmptyWriteDoesNothing() throws {
        let terminal = try self.makeTerminal()

        XCTAssertNoThrow(try terminal.write(Data()))
    }

    func testAWriteLargerThanTheTerminalBufferWaitsForTheReader() throws {
        let terminal = try self.makeTerminal()
        let deviceSide = self.openDeviceSide(of: terminal)
        let payload = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0) })
        let drained = XCTestExpectation(description: "the device side read everything")
        let result = ReadResult()
        DispatchQueue.global().async {
            result.bytes = readBytes(from: deviceSide, count: payload.count, timeout: 30)
            drained.fulfill()
        }

        try terminal.write(payload)

        self.wait(for: [drained], timeout: 40)
        XCTAssertEqual(result.bytes, payload)
    }

    func testReadingExactlyCountBytesLeavesTheRestForTheNextRead() throws {
        let terminal = try self.makeTerminal()
        let deviceSide = self.openDeviceSide(of: terminal)

        XCTAssertTrue(writeAll(Data("ABCDEF".utf8), to: deviceSide))

        XCTAssertEqual(terminal.read(count: 4, timeout: 10), Data("ABCD".utf8))
        XCTAssertEqual(terminal.read(count: 2, timeout: 10), Data("EF".utf8))
    }

    func testReadingCountBytesAnswersNilWhenTheyDoNotAllArrive() throws {
        let terminal = try self.makeTerminal()
        let deviceSide = self.openDeviceSide(of: terminal)
        XCTAssertTrue(writeAll(Data([0x01, 0x02]), to: deviceSide))
        let start = Date()

        let result = terminal.read(count: 5, timeout: 0.3)

        XCTAssertNil(result)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.25)
    }

    func testReadingCountBytesAnswersNilOnTimeoutWithNothingSent() throws {
        let terminal = try self.makeTerminal()
        _ = self.openDeviceSide(of: terminal)
        let start = Date()

        XCTAssertNil(terminal.read(count: 1, timeout: 0.3))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.25)
    }

    func testReadingWithATimeoutAnswersNothingWhenNothingComes() throws {
        let terminal = try self.makeTerminal()
        _ = self.openDeviceSide(of: terminal)

        XCTAssertEqual(terminal.read(timeout: 0.2), Data())
    }

    func testReadingWithATimeoutKeepsGoingWhileBytesKeepComing() throws {
        let terminal = try self.makeTerminal()
        let deviceSide = self.openDeviceSide(of: terminal)
        XCTAssertTrue(writeAll(Data("one ".utf8), to: deviceSide))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            _ = writeAll(Data("two".utf8), to: deviceSide)
        }

        XCTAssertEqual(terminal.read(timeout: 1.5), Data("one two".utf8))
    }

    func testWritingAfterCloseThrows() throws {
        let terminal = try self.makeTerminal()
        terminal.close()

        XCTAssertThrowsError(try terminal.write(Data([0x01]))) { error in
            XCTAssertEqual(error as? SerialStreamError, .writeFailed(code: EBADF))
        }
    }

    func testReadingAfterCloseAnswersNothing() throws {
        let terminal = try self.makeTerminal()
        terminal.close()

        XCTAssertEqual(terminal.read(timeout: 0.2), Data())
        XCTAssertNil(terminal.read(count: 1, timeout: 0.2))
    }

    func testClosingTwiceIsSafe() throws {
        let terminal = try self.makeTerminal()

        terminal.close()
        terminal.close()
    }

    func testClosingHangsUpTheDeviceSide() throws {
        let terminal = try self.makeTerminal()
        let deviceSide = self.openDeviceSide(of: terminal)

        terminal.close()

        // The device side now reads end of file (macOS, and Linux for a hung-up terminal) or EIO.
        var request = pollfd(fd: deviceSide, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&request, nfds_t(1), 10_000), 1)
        var byte: UInt8 = 0
        XCTAssertLessThanOrEqual(read(deviceSide, &byte, 1), 0)
    }
}
