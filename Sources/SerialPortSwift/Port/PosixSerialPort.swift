//
//  PosixSerialPort.swift
//  SerialPortSwift
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
/// through a dispatch read source, so received bytes never wait for the main thread; it starts once
/// the delegate has heard `streamDidOpen`. A read that finds the device gone (end of file, `ENXIO`,
/// `EIO`, `ENODEV`) closes the port with ``SerialCloseReason/removed``. Closing restores the line
/// settings the port found.
public final class PosixSerialPort: SerialByteStream {
    public let path: String
    public let name: String
    public let configuration: SerialPortConfiguration
    public weak var delegate: SerialByteStreamDelegate?

    private let executionQueue: ExecutionQueue

    // Everything below is confined to `executionQueue`.
    private var session: Session?
    private var sessionCount = 0
    private var lastModemLinesError: SerialStreamError?

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
        if let queue = queue {
            self.executionQueue = ExecutionQueue(queue: queue)
        } else {
            self.executionQueue = ExecutionQueue(label: "SerialPortSwift.PosixSerialPort")
        }
    }

    /// The port a ``SerialPortDescriptor`` describes, by its callout path and its name.
    public convenience init(
        descriptor: SerialPortDescriptor,
        configuration: SerialPortConfiguration = SerialPortConfiguration(),
        queue: DispatchQueue? = nil
    ) {
        self.init(path: descriptor.calloutPath, name: descriptor.name, configuration: configuration, queue: queue)
    }

    deinit {
        // Nothing else references the port any more, so its state is ours. The delegate hears nothing.
        if let session = self.session {
            self.session = nil
            session.shutDown()
        }
    }

    /// The path's last component, without a leading `cu.` or `tty.`.
    public static func defaultName(forPath path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = components.last else {
            return path
        }
        let component = String(last)
        for prefix in ["cu.", "tty."] where component.hasPrefix(prefix) && component.count > prefix.count {
            return String(component.dropFirst(prefix.count))
        }
        return component
    }

    public var isOpen: Bool {
        return self.executionQueue.sync { self.session != nil }
    }

    /// Why DTR and RTS could not be set at the last open, or `nil` when they were (or were not asked
    /// for).
    public var modemLinesError: SerialStreamError? {
        return self.executionQueue.sync { self.lastModemLinesError }
    }

    public func open() {
        let outcome = self.executionQueue.sync { self.openOnQueue() }
        switch outcome {
        case .alreadyOpen:
            return
        case .opened(let session):
            self.delegate?.streamDidOpen(self)
            // Reading starts only now, so no byte reaches the delegate before it has heard of the open.
            self.executionQueue.sync { self.startReadingOnQueue(session) }
        case .failed(let error):
            self.delegate?.streamDidClose(self, reason: .failed(error))
        }
    }

    public func close() {
        let calledOnPortQueue = self.executionQueue.isCurrent
        let descriptorClosed = self.executionQueue.sync { self.tearDownOnQueue() }
        guard let closed = descriptorClosed else {
            return
        }
        if !calledOnPortQueue {
            // The read source's cancel handler closes the descriptor on the port's queue. Wait for it,
            // so the path can be opened again as soon as this returns.
            closed.wait()
        }
        self.delegate?.streamDidClose(self, reason: .requested)
    }

    public func write(_ bytes: Data) {
        if bytes.isEmpty {
            return
        }
        self.executionQueue.run { self.writeOnQueue(bytes) }
    }

    /// The modem lines as the driver reports them now.
    public func readModemLines() -> Result<ModemLines, SerialStreamError> {
        return self.executionQueue.sync { self.driveModemLinesOnQueue(dtr: nil, rts: nil) }
    }

    /// Drives DTR and/or RTS (`nil` leaves a line as it is) and answers the lines as they are after.
    public func setModemLines(dtr: Bool?, rts: Bool?) -> Result<ModemLines, SerialStreamError> {
        return self.executionQueue.sync { self.driveModemLinesOnQueue(dtr: dtr, rts: rts) }
    }
}

// MARK: - Open, read, write and tear down

extension PosixSerialPort {
    /// How many bytes one read asks for.
    private static let readChunkSize = 1024

    private enum OpenOutcome {
        case alreadyOpen
        case opened(Session)
        case failed(SerialStreamError)
    }

    /// One time the port was open: its descriptor, what the line looked like before, and the source
    /// that reads it.
    private final class Session {
        let descriptor: Int32
        let number: Int
        let originalSettings: termios
        let exclusive: Bool
        /// Signalled by the read source's cancel handler once the descriptor is really closed.
        let descriptorClosed = DispatchSemaphore(value: 0)
        var readSource: DispatchSourceRead?
        var isReading = false

        init(descriptor: Int32, number: Int, originalSettings: termios, exclusive: Bool) {
            self.descriptor = descriptor
            self.number = number
            self.originalSettings = originalSettings
            self.exclusive = exclusive
        }

        func startReading() {
            if let source = self.readSource, !self.isReading {
                self.isReading = true
                source.resume()
            }
        }

        /// Gives the line back as it was found and cancels the read source, whose cancel handler
        /// closes the descriptor.
        func shutDown() {
            // The device may be gone, so a failure to restore is not worth reporting.
            var settings = self.originalSettings
            _ = Posix.tcsetattr(self.descriptor, TCSANOW, &settings)
            if self.exclusive {
                // Let go of the exclusive claim now rather than when the descriptor closes, so the
                // port can be reopened from a delegate callback.
                _ = Posix.ioctl(self.descriptor, Posix.requestNonExclusive)
                _ = Posix.lockFile(self.descriptor, LOCK_UN)
            }
            if let source = self.readSource {
                self.readSource = nil
                source.cancel()
                // A source that was never resumed does not run its cancel handler, and cannot be
                // released.
                if !self.isReading {
                    self.isReading = true
                    source.resume()
                }
            }
        }
    }

    /// Closes a descriptor an open gave up on. A pseudo-terminal keeps its exclusive claim after the
    /// descriptor closes, so the claim is withdrawn first.
    private static func abandon(_ descriptor: Int32, exclusive: Bool) {
        if exclusive {
            _ = Posix.ioctl(descriptor, Posix.requestNonExclusive)
        }
        _ = Posix.close(descriptor)
    }

    private func openOnQueue() -> OpenOutcome {
        if self.session != nil {
            return .alreadyOpen
        }
        let exclusive = self.configuration.exclusiveAccess

        var flags = O_RDWR | O_NOCTTY | O_NONBLOCK
        #if canImport(Darwin)
        if exclusive {
            flags |= O_EXLOCK
        }
        #endif
        let descriptor = Posix.open(self.path, flags)
        if descriptor < 0 {
            let code = errno
            if code == EAGAIN || code == EWOULDBLOCK || code == EBUSY {
                return .failed(.exclusiveAccessDenied(path: self.path))
            }
            return .failed(.openFailed(path: self.path, code: code))
        }

        #if !canImport(Darwin)
        // Linux has no O_EXLOCK: take the lock after opening.
        if exclusive && Posix.lockFile(descriptor, LOCK_EX | LOCK_NB) != 0 {
            _ = Posix.close(descriptor)
            return .failed(.exclusiveAccessDenied(path: self.path))
        }
        #endif
        if exclusive {
            _ = Posix.ioctl(descriptor, Posix.requestExclusive)
        }

        // Blocking I/O from here on.
        _ = Posix.fcntl(descriptor, F_SETFL, 0)

        var original = termios()
        if Posix.tcgetattr(descriptor, &original) != 0 {
            let code = errno
            PosixSerialPort.abandon(descriptor, exclusive: exclusive)
            return .failed(.configurationFailed(code: code))
        }

        let settings: PosixLineSettings
        switch Posix.lineSettings(from: original, for: self.configuration) {
        case .failure(let error):
            PosixSerialPort.abandon(descriptor, exclusive: exclusive)
            return .failed(error)
        case .success(let value):
            settings = value
        }
        var options = settings.options
        if Posix.tcsetattr(descriptor, TCSANOW, &options) != 0 {
            let code = errno
            PosixSerialPort.abandon(descriptor, exclusive: exclusive)
            return .failed(.configurationFailed(code: code))
        }
        if let customSpeed = settings.customSpeed, !Posix.applyCustomSpeed(customSpeed, to: descriptor) {
            _ = Posix.tcsetattr(descriptor, TCSANOW, &original)
            PosixSerialPort.abandon(descriptor, exclusive: exclusive)
            return .failed(.unsupportedBaudRate(customSpeed))
        }

        // A device without modem lines (a pseudo-terminal) still works.
        self.lastModemLinesError = nil
        if let levels = self.configuration.linesAfterOpen {
            let driven = Posix.driveModemLines(descriptor, dtr: levels.dtr, rts: levels.rts)
            if case .failure(let error) = driven {
                self.lastModemLinesError = error
            }
        }

        self.sessionCount += 1
        let number = self.sessionCount
        let session = Session(
            descriptor: descriptor,
            number: number,
            originalSettings: original,
            exclusive: exclusive
        )
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: self.executionQueue.queue)
        source.setEventHandler { [weak self] in
            self?.readAvailable(sessionNumber: number)
        }
        let descriptorClosed = session.descriptorClosed
        source.setCancelHandler {
            _ = Posix.close(descriptor)
            descriptorClosed.signal()
        }
        session.readSource = source
        self.session = session
        return .opened(session)
    }

    private func startReadingOnQueue(_ session: Session) {
        // The delegate may have closed the port from `streamDidOpen`.
        if self.session === session {
            session.startReading()
        }
    }

    /// Marks the port closed and shuts the session down. Answers the semaphore that tells when the
    /// descriptor is closed, or `nil` when the port was not open.
    private func tearDownOnQueue() -> DispatchSemaphore? {
        guard let session = self.session else {
            return nil
        }
        self.session = nil
        session.shutDown()
        return session.descriptorClosed
    }

    /// Closes the port for a reason it did not ask for, and tells the delegate.
    private func closeOnQueue(sessionNumber: Int, reason: SerialCloseReason) {
        guard let session = self.session, session.number == sessionNumber else {
            return
        }
        _ = self.tearDownOnQueue()
        self.delegate?.streamDidClose(self, reason: reason)
    }

    private func readAvailable(sessionNumber: Int) {
        guard let session = self.session, session.number == sessionNumber else {
            return
        }
        let descriptor = session.descriptor
        var buffer = [UInt8](repeating: 0, count: PosixSerialPort.readChunkSize)
        let result = buffer.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> (count: Int, code: Int32) in
            let count = Posix.read(descriptor, bytes.baseAddress, bytes.count)
            return (count, count < 0 ? errno : 0)
        }

        if result.count > 0 {
            self.delegate?.stream(self, didReceive: Data(buffer[0..<result.count]))
            return
        }
        if result.count == 0 {
            // End of file: the other end hung up.
            self.closeOnQueue(sessionNumber: sessionNumber, reason: .removed)
            return
        }
        switch result.code {
        case EINTR, EAGAIN, EWOULDBLOCK:
            return
        case ENXIO, EIO, ENODEV:
            self.closeOnQueue(sessionNumber: sessionNumber, reason: .removed)
        default:
            self.closeOnQueue(sessionNumber: sessionNumber, reason: .failed(.readFailed(code: result.code)))
        }
    }

    private func writeOnQueue(_ bytes: Data) {
        guard let session = self.session else {
            return
        }
        let descriptor = session.descriptor
        let code = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            return Posix.writeAll(descriptor, raw)
        }
        if code != 0 {
            // The delegate never hears of a failure before `write` returns: close later.
            let number = session.number
            self.executionQueue.async {
                self.closeOnQueue(sessionNumber: number, reason: .failed(.writeFailed(code: code)))
            }
        }
    }

    private func driveModemLinesOnQueue(dtr: Bool?, rts: Bool?) -> Result<ModemLines, SerialStreamError> {
        guard let session = self.session else {
            return .failure(.modemLinesUnavailable(code: EBADF))
        }
        return Posix.driveModemLines(session.descriptor, dtr: dtr, rts: rts)
    }
}
