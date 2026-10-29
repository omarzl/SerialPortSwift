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
///    waiting for carrier, and closed on `exec` so a child process cannot inherit it — with
///    ``SerialPortConfiguration/exclusiveAccess``, also with an exclusive lock and `TIOCEXCL`, so a
///    second opener is refused (``SerialStreamError/exclusiveAccessDenied(path:)``);
/// 2. keeps non-blocking I/O, so a write the device cannot take yet waits without holding up reads,
///    `close()` or anything else, and remembers the line settings it found;
/// 3. applies the configuration: raw, the data bits, parity and stop bits asked for, the flow control
///    asked for, `HUPCL | CLOCAL | CREAD`, `VMIN 1 / VTIME 2`, the speed (on macOS a speed the
///    terminal driver does not list is set with `IOSSIOSPEED`);
/// 4. drives DTR and RTS to ``SerialPortConfiguration/linesAfterOpen``. A device without modem lines
///    (a pseudo-terminal) keeps working: the failure is kept in ``modemLinesError``.
///
/// Open and close report synchronously, before they return. Reading happens on the port's queue
/// through a dispatch read source, so received bytes never wait for the main thread; it starts once
/// the delegate has heard `streamDidOpen`. A read that finds the device gone (end of file, `ENXIO`,
/// `EIO`, `ENODEV`) closes the port with ``SerialCloseReason/removed``.
///
/// Writing happens on the port's queue too: the port writes what the device takes at once and keeps
/// the rest, in order, to write as the device has room again. A write that finds the device gone
/// (`EIO`, `ENXIO`, `ENODEV`, `EPIPE`) closes the port with `removed`, any other write failure with
/// ``SerialStreamError/writeFailed(code:)``; both are reported later, on the port's queue.
///
/// Closing drops the bytes not yet written, switches hardware flow control off and waits for the
/// driver to send what it already holds — at most half a second — then restores the line settings
/// the port found. A close the device forced on the port (removed, failed) does not wait.
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
            session.shutDown(waitForOutput: true)
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
        let descriptorClosed = self.executionQueue.sync { self.tearDownOnQueue(waitForOutput: true) }
        guard let closed = descriptorClosed else {
            return
        }
        if !calledOnPortQueue {
            // The sources' cancel handlers close the descriptor on the port's queue. Wait for them,
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

    /// One time the port was open: its descriptor, what the line looked like before, the sources that
    /// read and write it, and the bytes the device has not taken yet.
    private final class Session {
        /// How long a close waits for the driver to send what it holds, in nanoseconds.
        private static let outputWaitLimit: UInt64 = 500_000_000
        /// How long one step of that wait lasts.
        private static let outputWaitSlice: TimeInterval = 0.005
        /// How many written bytes may sit at the front of the waiting bytes before the rest moves up.
        private static let compactionThreshold = 65_536

        let descriptor: Int32
        let number: Int
        let originalSettings: termios
        let exclusive: Bool
        /// Signalled once the descriptor is really closed, which happens when both sources are
        /// cancelled.
        let descriptorClosed = DispatchSemaphore(value: 0)
        var readSource: DispatchSourceRead?
        var isReading = false
        /// Resumed only while bytes wait for room; it is created suspended.
        var writeSource: DispatchSourceWrite?
        var isAwaitingRoom = false
        /// The bytes the device has not taken yet, in the order they were given: `pending` from
        /// `pendingOffset` on.
        private var pending = Data()
        private var pendingOffset = 0
        /// Set when a write failed or the port is closing; writes after that are dropped.
        private var writeFailed = false
        /// How many sources have yet to run their cancel handler. The descriptor closes after the last.
        private var sourcesToCancel = 2

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

        /// Called, on the port's queue, by the cancel handler of each source.
        func sourceDidCancel() {
            self.sourcesToCancel -= 1
            if self.sourcesToCancel == 0 {
                _ = Posix.close(self.descriptor)
                self.descriptorClosed.signal()
            }
        }

        // MARK: Writing

        private var hasPending: Bool {
            return self.pendingOffset < self.pending.count
        }

        /// Writes `bytes` behind any that are waiting: what the device takes goes out now, the rest
        /// waits for room. Answers the `errno` of a failure, or 0.
        func send(_ bytes: Data) -> Int32 {
            if self.writeFailed {
                return 0
            }
            if self.hasPending {
                self.pending.append(bytes)
                return 0
            }
            let descriptor = self.descriptor
            let result = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (written: Int, code: Int32) in
                return Posix.writeAvailable(descriptor, raw)
            }
            if result.code == 0 {
                return 0
            }
            if result.code != EAGAIN {
                return result.code
            }
            self.pending = bytes.subdata(in: (bytes.startIndex + result.written)..<bytes.endIndex)
            self.pendingOffset = 0
            self.awaitRoom()
            return 0
        }

        /// Writes what the device takes of the waiting bytes; the rest keeps waiting. Answers the
        /// `errno` of a failure, or 0.
        func drain() -> Int32 {
            if !self.hasPending {
                self.discardPending()
                return 0
            }
            let descriptor = self.descriptor
            let offset = self.pendingOffset
            let result = self.pending.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (written: Int, code: Int32) in
                return Posix.writeAvailable(descriptor, UnsafeRawBufferPointer(rebasing: raw[offset...]))
            }
            self.pendingOffset += result.written
            if result.code == 0 {
                self.discardPending()
                return 0
            }
            if result.code != EAGAIN {
                return result.code
            }
            // Written bytes do not stay for long: once enough of them sit at the front, the rest moves up.
            if self.pendingOffset >= Session.compactionThreshold && self.pendingOffset * 2 >= self.pending.count {
                let start = self.pending.startIndex + self.pendingOffset
                self.pending = self.pending.subdata(in: start..<self.pending.endIndex)
                self.pendingOffset = 0
            }
            return 0
        }

        /// Gives up on writing: drops the waiting bytes and ignores later ones.
        func abandonWrites() {
            self.writeFailed = true
            self.discardPending()
        }

        private func discardPending() {
            self.pending = Data()
            self.pendingOffset = 0
            self.stopAwaitingRoom()
        }

        private func awaitRoom() {
            if let source = self.writeSource, !self.isAwaitingRoom {
                self.isAwaitingRoom = true
                source.resume()
            }
        }

        private func stopAwaitingRoom() {
            if let source = self.writeSource, self.isAwaitingRoom {
                self.isAwaitingRoom = false
                source.suspend()
            }
        }

        // MARK: Closing

        /// Gives the line back as it was found and cancels the sources, whose cancel handlers close the
        /// descriptor. Bytes still waiting are dropped. With `waitForOutput`, the driver gets a moment
        /// to send what it already holds before the settings change under it.
        func shutDown(waitForOutput: Bool) {
            self.abandonWrites()
            // The device may be gone, so a failure from here on is not worth reporting.
            // Flow control goes off first: a stopped peer must not keep output from leaving.
            Posix.clearFlowControl(self.descriptor)
            if waitForOutput {
                self.waitForOutputToLeave()
            }
            var settings = self.originalSettings
            _ = Posix.tcsetattr(self.descriptor, TCSANOW, &settings)
            if self.exclusive {
                // Let go of the exclusive claim now rather than when the descriptor closes, so the
                // port can be reopened from a delegate callback.
                _ = Posix.ioctl(self.descriptor, Posix.requestNonExclusive)
                _ = Posix.lockFile(self.descriptor, LOCK_UN)
            }
            self.cancelSources()
        }

        /// Waits, in short steps, until the driver holds no more output, but no longer than
        /// `outputWaitLimit`. A driver that cannot say is not waited for.
        private func waitForOutputToLeave() {
            let deadline = DispatchTime.now().uptimeNanoseconds + Session.outputWaitLimit
            while let queued = Posix.outputQueueLength(self.descriptor), queued > 0 {
                if DispatchTime.now().uptimeNanoseconds >= deadline {
                    return
                }
                Thread.sleep(forTimeInterval: Session.outputWaitSlice)
            }
        }

        /// A source that is suspended runs no cancel handler and cannot be released: the read source
        /// has never been resumed if the port closed before reading started, the write source is
        /// suspended whenever nothing waits. Each is resumed before it is let go.
        private func cancelSources() {
            if let source = self.readSource {
                self.readSource = nil
                if !self.isReading {
                    self.isReading = true
                    source.resume()
                }
                source.cancel()
            }
            if let source = self.writeSource {
                self.writeSource = nil
                if !self.isAwaitingRoom {
                    self.isAwaitingRoom = true
                    source.resume()
                }
                source.cancel()
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

    /// Whether a failed write means the device went away, as a failed read does.
    private static func deviceIsGone(afterWriteFailure code: Int32) -> Bool {
        return code == EIO || code == ENXIO || code == ENODEV || code == EPIPE
    }

    private func openOnQueue() -> OpenOutcome {
        if self.session != nil {
            return .alreadyOpen
        }
        let exclusive = self.configuration.exclusiveAccess

        var flags = O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC
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
        // Linux has no O_EXLOCK: take the lock after opening. Only a lock someone else holds refuses
        // the open; if locking fails for another reason, the port carries on without the lock.
        if exclusive && Posix.lockFile(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN {
                _ = Posix.close(descriptor)
                return .failed(.exclusiveAccessDenied(path: self.path))
            }
        }
        #endif
        if exclusive {
            _ = Posix.ioctl(descriptor, Posix.requestExclusive)
        }

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
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: self.executionQueue.queue)
        readSource.setEventHandler { [weak self] in
            self?.readAvailable(sessionNumber: number)
        }
        readSource.setCancelHandler {
            session.sourceDidCancel()
        }
        session.readSource = readSource
        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: self.executionQueue.queue)
        writeSource.setEventHandler { [weak self] in
            self?.roomToWrite(sessionNumber: number)
        }
        writeSource.setCancelHandler {
            session.sourceDidCancel()
        }
        session.writeSource = writeSource
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
    private func tearDownOnQueue(waitForOutput: Bool) -> DispatchSemaphore? {
        guard let session = self.session else {
            return nil
        }
        self.session = nil
        session.shutDown(waitForOutput: waitForOutput)
        return session.descriptorClosed
    }

    /// Closes the port for a reason it did not ask for, and tells the delegate.
    private func closeOnQueue(sessionNumber: Int, reason: SerialCloseReason) {
        guard let session = self.session, session.number == sessionNumber else {
            return
        }
        _ = self.tearDownOnQueue(waitForOutput: false)
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
            // The descriptor is non-blocking: there was nothing to read after all.
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
        let code = session.send(bytes)
        if code != 0 {
            self.reportWriteFailure(of: session, code: code)
        }
    }

    /// The write source says the device can take more.
    private func roomToWrite(sessionNumber: Int) {
        guard let session = self.session, session.number == sessionNumber else {
            return
        }
        let code = session.drain()
        if code != 0 {
            self.reportWriteFailure(of: session, code: code)
        }
    }

    private func reportWriteFailure(of session: Session, code: Int32) {
        session.abandonWrites()
        let reason: SerialCloseReason
        if PosixSerialPort.deviceIsGone(afterWriteFailure: code) {
            reason = .removed
        } else {
            reason = .failed(.writeFailed(code: code))
        }
        // The delegate never hears of a failure before `write` returns: close later.
        let number = session.number
        self.executionQueue.async {
            self.closeOnQueue(sessionNumber: number, reason: reason)
        }
    }

    private func driveModemLinesOnQueue(dtr: Bool?, rts: Bool?) -> Result<ModemLines, SerialStreamError> {
        guard let session = self.session else {
            return .failure(.modemLinesUnavailable(code: EBADF))
        }
        return Posix.driveModemLines(session.descriptor, dtr: dtr, rts: rts)
    }
}
