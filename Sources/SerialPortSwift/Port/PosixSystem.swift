//
//  PosixSystem.swift
//  SerialPortSwift
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The C library calls the serial port needs, behind names that cannot be mistaken for the port's own
/// `open`, `close` and `write`, and the constants the two platforms spell differently.
///
/// `ioctl` requests are macros built from `_IO*`, which Darwin does not import, so they are written out
/// here for Darwin. Linux numbers differ between processor architectures, so there they are the
/// constants Glibc imports.
enum Posix {
    // MARK: ioctl requests

    #if canImport(Darwin)
    /// `TIOCEXCL`: refuse further opens of the terminal.
    static let requestExclusive: UInt = 0x2000_740D
    /// `TIOCNXCL`: allow opens again.
    static let requestNonExclusive: UInt = 0x2000_740E
    /// `TIOCMGET`: read the modem lines.
    static let requestModemGet: UInt = 0x4004_746A
    /// `TIOCMSET`: write the modem lines.
    static let requestModemSet: UInt = 0x8004_746D
    /// `TIOCOUTQ`: the number of bytes in the output queue, as an `int`.
    static let requestOutputQueue: UInt = 0x4004_7473
    /// `IOSSIOSPEED`: set any speed; takes a `speed_t`.
    static let requestSetSpeed: UInt = 0x8008_5402
    #else
    // The numbers differ between processor architectures, so these are the ones Glibc imports.
    static let requestExclusive = UInt(TIOCEXCL)
    static let requestNonExclusive = UInt(TIOCNXCL)
    static let requestModemGet = UInt(TIOCMGET)
    static let requestModemSet = UInt(TIOCMSET)
    static let requestOutputQueue = UInt(TIOCOUTQ)
    #endif

    // MARK: Modem line bits (the same on both platforms)

    static let modemDTR: Int32 = 0o002
    static let modemRTS: Int32 = 0o004
    static let modemCTS: Int32 = 0o040
    static let modemDCD: Int32 = 0o100
    static let modemRI: Int32 = 0o200
    static let modemDSR: Int32 = 0o400

    // MARK: Shims

    static func open(_ path: String, _ flags: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.open(path, flags)
        #else
        return Glibc.open(path, flags)
        #endif
    }

    static func close(_ descriptor: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.close(descriptor)
        #else
        return Glibc.close(descriptor)
        #endif
    }

    static func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.read(descriptor, buffer, count)
        #else
        return Glibc.read(descriptor, buffer, count)
        #endif
    }

    static func write(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.write(descriptor, buffer, count)
        #else
        return Glibc.write(descriptor, buffer, count)
        #endif
    }

    static func ioctl(_ descriptor: Int32, _ request: UInt) -> Int32 {
        #if canImport(Darwin)
        return Darwin.ioctl(descriptor, request)
        #else
        return Glibc.ioctl(descriptor, request)
        #endif
    }

    /// An `ioctl` that reads or writes the value `argument` points to.
    static func ioctl(_ descriptor: Int32, _ request: UInt, _ argument: UnsafeMutableRawPointer) -> Int32 {
        #if canImport(Darwin)
        return Darwin.ioctl(descriptor, request, argument)
        #else
        return Glibc.ioctl(descriptor, request, argument)
        #endif
    }

    /// `flock(2)`. Called unqualified and under another name: `struct flock` shares the name, and a
    /// module-qualified `flock` finds the structure instead of the function.
    static func lockFile(_ descriptor: Int32, _ operation: Int32) -> Int32 {
        return flock(descriptor, operation)
    }

    static func tcgetattr(_ descriptor: Int32, _ options: inout termios) -> Int32 {
        #if canImport(Darwin)
        return Darwin.tcgetattr(descriptor, &options)
        #else
        return Glibc.tcgetattr(descriptor, &options)
        #endif
    }

    static func tcsetattr(_ descriptor: Int32, _ action: Int32, _ options: inout termios) -> Int32 {
        #if canImport(Darwin)
        return Darwin.tcsetattr(descriptor, action, &options)
        #else
        return Glibc.tcsetattr(descriptor, action, &options)
        #endif
    }

    static func cfmakeraw(_ options: inout termios) {
        #if canImport(Darwin)
        Darwin.cfmakeraw(&options)
        #else
        Glibc.cfmakeraw(&options)
        #endif
    }

    static func cfsetspeed(_ options: inout termios, _ speed: speed_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.cfsetspeed(&options, speed)
        #else
        return Glibc.cfsetspeed(&options, speed)
        #endif
    }
}

// MARK: - Writing

extension Posix {
    /// Writes as much of `bytes` as the descriptor takes without waiting, retrying after a signal.
    /// Answers how many bytes went out and why it stopped: 0 when all of them did, `EAGAIN` when the
    /// descriptor is full, or the `errno` of a failure.
    static func writeAvailable(
        _ descriptor: Int32,
        _ bytes: UnsafeRawBufferPointer
    ) -> (written: Int, code: Int32) {
        guard let base = bytes.baseAddress else {
            return (0, 0)
        }
        var offset = 0
        while offset < bytes.count {
            let count = Posix.write(descriptor, base + offset, bytes.count - offset)
            if count > 0 {
                offset += count
                continue
            }
            if count < 0 {
                let code = errno
                if code == EINTR {
                    continue
                }
                return (offset, code == EWOULDBLOCK ? EAGAIN : code)
            }
            // A write that takes nothing and does not fail: the descriptor is full.
            return (offset, EAGAIN)
        }
        return (offset, 0)
    }

    /// How many bytes the driver still holds to send, or `nil` when it cannot say.
    static func outputQueueLength(_ descriptor: Int32) -> Int? {
        var count: Int32 = 0
        if Posix.ioctl(descriptor, requestOutputQueue, &count) != 0 {
            return nil
        }
        return Int(count)
    }
}

// MARK: - Modem lines

extension Posix {
    static func modemLines(fromBits bits: Int32) -> ModemLines {
        var lines: ModemLines = []
        if bits & modemDTR != 0 {
            lines.insert(.dtr)
        }
        if bits & modemRTS != 0 {
            lines.insert(.rts)
        }
        if bits & modemCTS != 0 {
            lines.insert(.cts)
        }
        if bits & modemDSR != 0 {
            lines.insert(.dsr)
        }
        if bits & modemDCD != 0 {
            lines.insert(.dcd)
        }
        if bits & modemRI != 0 {
            lines.insert(.ri)
        }
        return lines
    }

    static func readModemLines(_ descriptor: Int32) -> Result<ModemLines, SerialStreamError> {
        var bits: Int32 = 0
        if Posix.ioctl(descriptor, requestModemGet, &bits) != 0 {
            return .failure(.modemLinesUnavailable(code: errno))
        }
        return .success(modemLines(fromBits: bits))
    }

    /// Drives DTR and RTS (`nil` leaves a line alone) and answers the lines as they are afterwards.
    static func driveModemLines(
        _ descriptor: Int32,
        dtr: Bool?,
        rts: Bool?
    ) -> Result<ModemLines, SerialStreamError> {
        if dtr == nil && rts == nil {
            return readModemLines(descriptor)
        }
        var bits: Int32 = 0
        if Posix.ioctl(descriptor, requestModemGet, &bits) != 0 {
            return .failure(.modemLinesUnavailable(code: errno))
        }
        if let dtr = dtr {
            bits = dtr ? (bits | modemDTR) : (bits & ~modemDTR)
        }
        if let rts = rts {
            bits = rts ? (bits | modemRTS) : (bits & ~modemRTS)
        }
        if Posix.ioctl(descriptor, requestModemSet, &bits) != 0 {
            return .failure(.modemLinesUnavailable(code: errno))
        }
        return readModemLines(descriptor)
    }
}

// MARK: - Line settings

/// The terminal settings a configuration asks for.
struct PosixLineSettings {
    var options: termios
    /// A speed the terminal driver does not list. The settings carry a standard speed instead, and
    /// the port sets this one with `IOSSIOSPEED` once they are applied. Always `nil` on Linux.
    var customSpeed: Int?
}

extension Posix {
    /// The speeds the Darwin terminal driver lists, which `cfsetspeed` takes as plain numbers.
    private static let darwinStandardRates: [Int] = [
        50, 75, 110, 134, 150, 200, 300, 600, 1200, 1800, 2400, 4800, 7200, 9600, 14400, 19200,
        28800, 38400, 57600, 76800, 115200, 230400
    ]

    #if !canImport(Darwin)
    /// The `Bxxx` constant for a speed, or `nil` when Linux has none.
    private static func linuxSpeed(forRate rate: Int) -> speed_t? {
        switch rate {
        case 50: return speed_t(B50)
        case 75: return speed_t(B75)
        case 110: return speed_t(B110)
        case 134: return speed_t(B134)
        case 150: return speed_t(B150)
        case 200: return speed_t(B200)
        case 300: return speed_t(B300)
        case 600: return speed_t(B600)
        case 1200: return speed_t(B1200)
        case 1800: return speed_t(B1800)
        case 2400: return speed_t(B2400)
        case 4800: return speed_t(B4800)
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115200: return speed_t(B115200)
        case 230400: return speed_t(B230400)
        case 460800: return speed_t(B460800)
        case 500000: return speed_t(B500000)
        case 576000: return speed_t(B576000)
        case 921600: return speed_t(B921600)
        case 1000000: return speed_t(B1000000)
        case 1152000: return speed_t(B1152000)
        case 1500000: return speed_t(B1500000)
        case 2000000: return speed_t(B2000000)
        case 2500000: return speed_t(B2500000)
        case 3000000: return speed_t(B3000000)
        case 3500000: return speed_t(B3500000)
        case 4000000: return speed_t(B4000000)
        default: return nil
        }
    }
    #endif

    /// Sets the speed of `options`; answers the speed to set afterwards with `IOSSIOSPEED`, if any.
    private static func applySpeed(
        _ rate: Int,
        to options: inout termios
    ) -> Result<Int?, SerialStreamError> {
        #if canImport(Darwin)
        if rate <= 0 {
            return .failure(.unsupportedBaudRate(rate))
        }
        let isStandard = darwinStandardRates.contains(rate)
        let listed = isStandard ? rate : 9600
        if Posix.cfsetspeed(&options, speed_t(listed)) != 0 {
            return .failure(.unsupportedBaudRate(rate))
        }
        return .success(isStandard ? nil : rate)
        #else
        guard let speed = linuxSpeed(forRate: rate), Posix.cfsetspeed(&options, speed) == 0 else {
            return .failure(.unsupportedBaudRate(rate))
        }
        return .success(nil)
        #endif
    }

    /// Sets a speed the terminal driver does not list. Only Darwin can; elsewhere it answers `false`.
    static func applyCustomSpeed(_ rate: Int, to descriptor: Int32) -> Bool {
        #if canImport(Darwin)
        var speed = speed_t(rate)
        return Posix.ioctl(descriptor, requestSetSpeed, &speed) == 0
        #else
        return false
        #endif
    }

    /// The flow-control bits of `c_cflag` for this platform.
    private static func flowControlBits(
        rtsCts: Bool,
        dtrDsr: Bool,
        dcdOutput: Bool
    ) -> (enabled: tcflag_t, mask: tcflag_t) {
        #if canImport(Darwin)
        let rtsCtsBits = tcflag_t(CCTS_OFLOW) | tcflag_t(CRTS_IFLOW)
        let dtrDsrBits = tcflag_t(CDTR_IFLOW) | tcflag_t(CDSR_OFLOW)
        let dcdBits = tcflag_t(CCAR_OFLOW)
        let mask = rtsCtsBits | dtrDsrBits | dcdBits
        var enabled: tcflag_t = 0
        if rtsCts {
            enabled |= rtsCtsBits
        }
        if dtrDsr {
            enabled |= dtrDsrBits
        }
        if dcdOutput {
            enabled |= dcdBits
        }
        return (enabled, mask)
        #else
        let rtsCtsBits = tcflag_t(CRTSCTS)
        return (rtsCts ? rtsCtsBits : 0, rtsCtsBits)
        #endif
    }

    /// Switches hardware flow control off on a line that is open, so output a stopped peer was holding
    /// back can leave. A failure is ignored: the device may be gone.
    static func clearFlowControl(_ descriptor: Int32) {
        var options = termios()
        if Posix.tcgetattr(descriptor, &options) != 0 {
            return
        }
        let mask = flowControlBits(rtsCts: true, dtrDsr: true, dcdOutput: true).mask
        options.c_cflag &= ~mask
        _ = Posix.tcsetattr(descriptor, TCSANOW, &options)
    }

    /// The settings that put a line in the state `configuration` asks for, starting from `current` so
    /// the bits this library does not manage stay as the driver had them.
    static func lineSettings(
        from current: termios,
        for configuration: SerialPortConfiguration
    ) -> Result<PosixLineSettings, SerialStreamError> {
        var options = current

        // Raw: no line editing, no signals, no character translation.
        Posix.cfmakeraw(&options)
        withUnsafeMutableBytes(of: &options.c_cc) { (bytes: UnsafeMutableRawBufferPointer) -> Void in
            bytes[Int(VMIN)] = 1
            bytes[Int(VTIME)] = 2
        }

        switch configuration.dataBits {
        case .five: options.c_cflag = (options.c_cflag & ~tcflag_t(CSIZE)) | tcflag_t(CS5)
        case .six: options.c_cflag = (options.c_cflag & ~tcflag_t(CSIZE)) | tcflag_t(CS6)
        case .seven: options.c_cflag = (options.c_cflag & ~tcflag_t(CSIZE)) | tcflag_t(CS7)
        case .eight: options.c_cflag = (options.c_cflag & ~tcflag_t(CSIZE)) | tcflag_t(CS8)
        }

        switch configuration.parity {
        case .none:
            options.c_cflag &= ~(tcflag_t(PARENB) | tcflag_t(PARODD))
        case .odd:
            options.c_cflag |= tcflag_t(PARENB) | tcflag_t(PARODD)
        case .even:
            options.c_cflag |= tcflag_t(PARENB)
            options.c_cflag &= ~tcflag_t(PARODD)
        }

        switch configuration.stopBits {
        case .one: options.c_cflag &= ~tcflag_t(CSTOPB)
        case .two: options.c_cflag |= tcflag_t(CSTOPB)
        }

        if configuration.echo {
            options.c_lflag |= tcflag_t(ECHO)
        } else {
            options.c_lflag &= ~tcflag_t(ECHO)
        }

        let flow = flowControlBits(
            rtsCts: configuration.flowControl.contains(.rtsCts),
            dtrDsr: configuration.flowControl.contains(.dtrDsr),
            dcdOutput: configuration.flowControl.contains(.dcdOutput)
        )
        options.c_cflag = (options.c_cflag & ~flow.mask) | flow.enabled

        options.c_cflag |= tcflag_t(HUPCL) | tcflag_t(CLOCAL) | tcflag_t(CREAD)
        options.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ISIG))

        switch applySpeed(configuration.baudRate, to: &options) {
        case .failure(let error):
            return .failure(error)
        case .success(let customSpeed):
            return .success(PosixLineSettings(options: options, customSpeed: customSpeed))
        }
    }
}
