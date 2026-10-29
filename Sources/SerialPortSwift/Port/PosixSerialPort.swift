//
//  PosixSerialPort.swift
//  SerialPortSwift
//

import Foundation

/// A serial port opened by path — `/dev/cu.usbserial-1420` on macOS, `/dev/ttyUSB0` on Linux —
/// as a ``SerialByteStream``.
///
/// Opening it:
/// 1. opens the device for reading and writing without making it the controlling terminal, without
///    waiting for carrier, and — with ``SerialPortConfiguration/exclusiveAccess`` — with an exclusive
///    lock and `TIOCEXCL`, so a second opener is refused
///    (``SerialStreamError/exclusiveAccessDenied(path:)``);
/// 2. switches the descriptor back to blocking I/O and remembers the line settings it found;
/// 3. applies the configuration: raw, the data bits, parity and stop bits asked for, the flow control
///    asked for, `HUPCL | CLOCAL | CREAD`, `VMIN 1 / VTIME 2`, the speed (on macOS a speed the
///    terminal driver does not list is set with `IOSSIOSPEED`);
/// 4. drives DTR and RTS to ``SerialPortConfiguration/linesAfterOpen``. A device without modem lines
///    (a pseudo-terminal) keeps working: the failure is kept in ``modemLinesError``.
///
/// Open and close report synchronously, before they return. Reading happens on the port's queue
/// through a dispatch read source, so received bytes never wait for the main thread. A read that finds
/// the device gone (end of file, `ENXIO`, `EIO`, `ENODEV`) closes the port with
/// ``SerialCloseReason/removed``. Closing restores the line settings the port found.
public final class PosixSerialPort: SerialByteStream {
    public let path: String
    public let name: String
    public let configuration: SerialPortConfiguration
    public weak var delegate: SerialByteStreamDelegate?

    /// - Parameters:
    ///   - name: defaults to the path's last component without a leading `cu.` or `tty.`.
    ///   - queue: the serial queue the port reads and writes on; by default it makes its own.
    public init(
        path: String,
        name: String? = nil,
        configuration: SerialPortConfiguration = SerialPortConfiguration(),
        queue: DispatchQueue? = nil
    ) {
        self.path = path
        self.name = name ?? PosixSerialPort.defaultName(forPath: path)
        self.configuration = configuration
        fatalError("Not implemented yet")
    }

    /// The port a ``SerialPortDescriptor`` describes, by its callout path and its name.
    public convenience init(
        descriptor: SerialPortDescriptor,
        configuration: SerialPortConfiguration = SerialPortConfiguration(),
        queue: DispatchQueue? = nil
    ) {
        self.init(path: descriptor.calloutPath, name: descriptor.name, configuration: configuration, queue: queue)
    }

    /// The path's last component, without a leading `cu.` or `tty.`.
    public static func defaultName(forPath path: String) -> String {
        fatalError("Not implemented yet")
    }

    public var isOpen: Bool {
        fatalError("Not implemented yet")
    }

    /// Why DTR and RTS could not be set at the last open, or `nil` when they were (or were not asked
    /// for).
    public var modemLinesError: SerialStreamError? {
        fatalError("Not implemented yet")
    }

    public func open() {
        fatalError("Not implemented yet")
    }

    public func close() {
        fatalError("Not implemented yet")
    }

    public func write(_ bytes: Data) {
        fatalError("Not implemented yet")
    }

    /// The modem lines as the driver reports them now.
    public func readModemLines() -> Result<ModemLines, SerialStreamError> {
        fatalError("Not implemented yet")
    }

    /// Drives DTR and/or RTS (`nil` leaves a line as it is) and answers the lines as they are after.
    public func setModemLines(dtr: Bool?, rts: Bool?) -> Result<ModemLines, SerialStreamError> {
        fatalError("Not implemented yet")
    }
}
