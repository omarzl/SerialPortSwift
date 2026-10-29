//
//  PseudoTerminal.swift
//  SerialPortSwiftSimulation
//

import Foundation
import SerialPortSwift

/// A pseudo-terminal pair: ``devicePath`` is a terminal device a ``PosixSerialPort`` can open, and
/// this object is the device on its other end — what the port writes, it reads, and the other way
/// round. A serial port test that needs no hardware.
///
/// Closing it hangs up the device side, which a port reading there sees as its device going away.
public final class PseudoTerminal {
    /// The terminal device to open: `/dev/pts/3` on Linux, `/dev/ttys004` on macOS.
    public let devicePath: String

    /// Opens a new pair.
    public init() throws {
        fatalError("Not implemented yet")
    }

    deinit {
        // Implementations close the controller side here if it is still open.
    }

    /// Sends `bytes` to the port.
    public func write(_ bytes: Data) throws {
        fatalError("Not implemented yet")
    }

    /// What the port sent within `timeout`: everything that arrives until nothing more comes for
    /// `timeout`, or an empty `Data` when nothing did.
    public func read(timeout: TimeInterval) -> Data {
        fatalError("Not implemented yet")
    }

    /// Exactly `count` bytes from the port, or `nil` when they did not all arrive within `timeout`.
    public func read(count: Int, timeout: TimeInterval) -> Data? {
        fatalError("Not implemented yet")
    }

    /// Hangs up: closes this end. Safe to call twice.
    public func close() {
        fatalError("Not implemented yet")
    }
}
