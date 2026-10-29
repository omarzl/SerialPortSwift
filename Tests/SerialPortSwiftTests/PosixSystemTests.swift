//
//  PosixSystemTests.swift
//  SerialPortSwiftTests
//

import Foundation
import SerialPortSwiftSimulation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import SerialPortSwift

/// A pipe whose ends never block, for trying a descriptor that fills up.
private struct NonBlockingPipe {
    let readEnd: Int32
    let writeEnd: Int32

    init() {
        var ends: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&ends), 0, "pipe failed: errno \(errno)")
        self.readEnd = ends[0]
        self.writeEnd = ends[1]
        for descriptor in ends where descriptor >= 0 {
            let flags = fcntl(descriptor, F_GETFL)
            XCTAssertEqual(fcntl(descriptor, F_SETFL, flags | O_NONBLOCK), 0)
        }
    }

    func tearDown() {
        _ = close(self.readEnd)
        _ = close(self.writeEnd)
    }

    /// Everything the pipe holds right now.
    func drain() -> Int {
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                return read(self.readEnd, raw.baseAddress, raw.count)
            }
            if count <= 0 {
                return total
            }
            total += count
        }
    }
}

final class PosixSystemTests: XCTestCase {
    // MARK: Modem line bits

    func testEachModemLineBitMapsToItsLine() {
        XCTAssertEqual(Posix.modemLines(fromBits: 0), [])
        XCTAssertEqual(Posix.modemLines(fromBits: Posix.modemDTR), [.dtr])
        XCTAssertEqual(Posix.modemLines(fromBits: Posix.modemRTS), [.rts])
        XCTAssertEqual(Posix.modemLines(fromBits: Posix.modemCTS), [.cts])
        XCTAssertEqual(Posix.modemLines(fromBits: Posix.modemDSR), [.dsr])
        XCTAssertEqual(Posix.modemLines(fromBits: Posix.modemDCD), [.dcd])
        XCTAssertEqual(Posix.modemLines(fromBits: Posix.modemRI), [.ri])
    }

    func testTheModemLineBitsAreTheOnesTheSystemDefines() {
        XCTAssertEqual(Posix.modemDTR, Int32(TIOCM_DTR))
        XCTAssertEqual(Posix.modemRTS, Int32(TIOCM_RTS))
        XCTAssertEqual(Posix.modemCTS, Int32(TIOCM_CTS))
        XCTAssertEqual(Posix.modemDSR, Int32(TIOCM_DSR))
        XCTAssertEqual(Posix.modemDCD, Int32(TIOCM_CAR))
        XCTAssertEqual(Posix.modemRI, Int32(TIOCM_RNG))
    }

    func testEveryCombinationOfModemLineBitsMapsToTheSameLines() {
        let table: [(bit: Int32, line: ModemLines)] = [
            (Posix.modemDTR, .dtr),
            (Posix.modemRTS, .rts),
            (Posix.modemCTS, .cts),
            (Posix.modemDSR, .dsr),
            (Posix.modemDCD, .dcd),
            (Posix.modemRI, .ri)
        ]
        for subset in 0..<(1 << table.count) {
            var bits: Int32 = 0
            var expected: ModemLines = []
            for (index, entry) in table.enumerated() where subset & (1 << index) != 0 {
                bits |= entry.bit
                expected.insert(entry.line)
            }
            XCTAssertEqual(Posix.modemLines(fromBits: bits), expected, "bits \(bits)")
        }
    }

    func testBitsThatAreNotModemLinesAreIgnored() {
        let others = Int32(TIOCM_LE) | Int32(TIOCM_ST) | Int32(TIOCM_SR)

        XCTAssertEqual(Posix.modemLines(fromBits: others), [])
        XCTAssertEqual(Posix.modemLines(fromBits: others | Posix.modemCTS | Posix.modemDTR), [.cts, .dtr])
        // Bits above the ones the system defines.
        XCTAssertEqual(Posix.modemLines(fromBits: ~0), [.dtr, .rts, .cts, .dsr, .dcd, .ri])
    }

    // MARK: Writing without waiting

    func testWritingToAFullDescriptorAnswersWhatWentOutAndEAGAIN() {
        let pipe = NonBlockingPipe()
        defer { pipe.tearDown() }
        let payload = [UInt8](repeating: 0x5A, count: 4 * 1024 * 1024)
        var offset = 0
        var fullOnce = false

        while offset < payload.count {
            let result = payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (written: Int, code: Int32) in
                return Posix.writeAvailable(pipe.writeEnd, UnsafeRawBufferPointer(rebasing: raw[offset...]))
            }
            offset += result.written
            if result.code == 0 {
                break
            }
            XCTAssertEqual(result.code, EAGAIN)
            fullOnce = true
            // Make room for the next round; a pipe that took nothing and has nothing to read is stuck.
            if pipe.drain() == 0 && result.written == 0 {
                XCTFail("the pipe neither took bytes nor had any to give back")
                return
            }
        }

        XCTAssertTrue(fullOnce, "a pipe of a few kilobytes took four megabytes at once")
        XCTAssertEqual(offset, payload.count)
    }

    func testWritingNothingAnswersZero() {
        let pipe = NonBlockingPipe()
        defer { pipe.tearDown() }
        let nothing = UnsafeRawBufferPointer(start: nil, count: 0)

        let result = Posix.writeAvailable(pipe.writeEnd, nothing)

        XCTAssertEqual(result.written, 0)
        XCTAssertEqual(result.code, 0)
    }

    func testWritingToADescriptorThatIsNotOpenAnswersItsError() {
        var byte: UInt8 = 0x01

        let result = withUnsafeBytes(of: &byte) { (raw: UnsafeRawBufferPointer) -> (written: Int, code: Int32) in
            return Posix.writeAvailable(-1, raw)
        }

        XCTAssertEqual(result.written, 0)
        XCTAssertEqual(result.code, EBADF)
    }

    // MARK: The output queue

    func testThePendingOutputOfSomethingThatIsNotATerminalIsUnknown() {
        let pipe = NonBlockingPipe()
        defer { pipe.tearDown() }

        XCTAssertNil(Posix.outputQueueLength(pipe.writeEnd))
        XCTAssertNil(Posix.outputQueueLength(-1))
    }

    func testTheOutputQueueOfAnIdleTerminalIsEmpty() throws {
        let terminal = try PseudoTerminal()
        defer { terminal.close() }
        let descriptor = open(terminal.devicePath, O_RDWR | O_NOCTTY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { _ = close(descriptor) }

        let queued = Posix.outputQueueLength(descriptor)

        #if canImport(Darwin)
        // The request number is written out by hand on macOS: the terminal driver has to accept it.
        XCTAssertNotNil(queued)
        #endif
        if let queued = queued {
            XCTAssertEqual(queued, 0)
        }
    }

    func testFlowControlIsSwitchedOffOnAnOpenLine() throws {
        let terminal = try PseudoTerminal()
        defer { terminal.close() }
        let descriptor = open(terminal.devicePath, O_RDWR | O_NOCTTY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { _ = close(descriptor) }
        var options = termios()
        XCTAssertEqual(tcgetattr(descriptor, &options), 0)
        #if canImport(Darwin)
        let flowBits = tcflag_t(CCTS_OFLOW) | tcflag_t(CRTS_IFLOW)
        #else
        let flowBits = tcflag_t(CRTSCTS)
        #endif
        options.c_cflag |= flowBits
        XCTAssertEqual(tcsetattr(descriptor, TCSANOW, &options), 0)
        var before = termios()
        XCTAssertEqual(tcgetattr(descriptor, &before), 0)
        if before.c_cflag & flowBits == 0 {
            // A driver that does not keep the bits has nothing to clear.
            return
        }

        Posix.clearFlowControl(descriptor)

        var after = termios()
        XCTAssertEqual(tcgetattr(descriptor, &after), 0)
        XCTAssertEqual(after.c_cflag & flowBits, 0)
        // Nothing else changed.
        XCTAssertEqual(after.c_cflag | flowBits, before.c_cflag | flowBits)
    }
}
