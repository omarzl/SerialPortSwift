//
//  SerialPortConfiguration.swift
//  SerialPortSwift
//

import Foundation

/// How a ``PosixSerialPort`` sets up its line when it opens.
///
/// The port is always raw (no line editing, no signals, no character translation), keeps the
/// receiver on (`CREAD`), ignores the modem's carrier for reading (`CLOCAL`) and hangs up on close
/// (`HUPCL`).
public struct SerialPortConfiguration: Equatable {
    public enum DataBits: Int, Equatable {
        case five = 5
        case six = 6
        case seven = 7
        case eight = 8
    }

    public enum Parity: Equatable {
        case none
        case odd
        case even
    }

    public enum StopBits: Equatable {
        case one
        case two
    }

    /// Hardware flow control. Empty for none.
    public struct FlowControl: OptionSet, Equatable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// RTS/CTS.
        public static let rtsCts = FlowControl(rawValue: 1 << 0)
        /// DTR/DSR. macOS only; ignored elsewhere.
        public static let dtrDsr = FlowControl(rawValue: 1 << 1)
        /// Output gated on DCD. macOS only; ignored elsewhere.
        public static let dcdOutput = FlowControl(rawValue: 1 << 2)
    }

    /// The levels DTR and RTS are driven to right after the port opens.
    public struct LineLevels: Equatable {
        public var dtr: Bool
        public var rts: Bool

        public init(dtr: Bool, rts: Bool) {
            self.dtr = dtr
            self.rts = rts
        }
    }

    public var baudRate: Int
    public var dataBits: DataBits
    public var parity: Parity
    public var stopBits: StopBits
    public var flowControl: FlowControl
    /// Whether the device echoes what it receives back to the sender.
    public var echo: Bool
    /// DTR and RTS after opening, or `nil` to leave them as the driver set them. Both low by default.
    public var linesAfterOpen: LineLevels?
    /// Whether to refuse other openers while this port is open.
    public var exclusiveAccess: Bool

    public init(
        baudRate: Int = 9600,
        dataBits: DataBits = .eight,
        parity: Parity = .none,
        stopBits: StopBits = .one,
        flowControl: FlowControl = [],
        echo: Bool = false,
        linesAfterOpen: LineLevels? = LineLevels(dtr: false, rts: false),
        exclusiveAccess: Bool = true
    ) {
        self.baudRate = baudRate
        self.dataBits = dataBits
        self.parity = parity
        self.stopBits = stopBits
        self.flowControl = flowControl
        self.echo = echo
        self.linesAfterOpen = linesAfterOpen
        self.exclusiveAccess = exclusiveAccess
    }
}

/// The modem-control lines of a serial port.
public struct ModemLines: OptionSet, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Data Terminal Ready (an output).
    public static let dtr = ModemLines(rawValue: 1 << 0)
    /// Request To Send (an output).
    public static let rts = ModemLines(rawValue: 1 << 1)
    /// Clear To Send (an input).
    public static let cts = ModemLines(rawValue: 1 << 2)
    /// Data Set Ready (an input).
    public static let dsr = ModemLines(rawValue: 1 << 3)
    /// Data Carrier Detect (an input).
    public static let dcd = ModemLines(rawValue: 1 << 4)
    /// Ring Indicator (an input).
    public static let ri = ModemLines(rawValue: 1 << 5)
}
