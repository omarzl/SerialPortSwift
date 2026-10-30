//
//  SerialCloseReason.swift
//  SerialPortSwift
//

import Foundation

/// Why a stream or a transport closed.
public enum SerialCloseReason: Equatable {
    /// Someone called `close()`.
    case requested
    /// The device went away: unplugged, or its other end hung up.
    case removed
    /// It could not open, or it failed while open.
    case failed(SerialStreamError)
}

/// What went wrong on a stream. `code` is the `errno` the system answered.
public enum SerialStreamError: Error, Equatable {
    /// `open(2)` failed for `path`.
    case openFailed(path: String, code: Int32)
    /// Another owner holds `path` for exclusive access.
    case exclusiveAccessDenied(path: String)
    /// The line settings could not be read or applied.
    case configurationFailed(code: Int32)
    /// The system does not support this speed on this device.
    case unsupportedBaudRate(Int)
    /// The modem-control lines (DTR, RTS, …) could not be read or set. A pseudo-terminal has none.
    case modemLinesUnavailable(code: Int32)
    case readFailed(code: Int32)
    case writeFailed(code: Int32)
    /// An error from another layer — a driver wrapped behind ``SerialTransport`` — kept by its
    /// domain, code and description.
    case system(domain: String, code: Int, description: String)
}

// `Sendable` is a marker with nothing at run time; a compiler older than 5.5 does not know it.
#if compiler(>=5.5)
    extension SerialCloseReason: Sendable {}
    extension SerialStreamError: Sendable {}
#endif
