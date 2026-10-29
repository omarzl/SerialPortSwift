//
//  PseudoTerminal.swift
//  SerialPortSwiftSimulation
//

import Foundation
import SerialPortSwift
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if !canImport(Darwin)
// Swift's Glibc module does not import the pseudo-terminal calls, so they are declared by symbol.
@_silgen_name("posix_openpt") fileprivate func glibcOpenPseudoTerminal(_ flags: Int32) -> Int32
@_silgen_name("grantpt") fileprivate func glibcGrantPseudoTerminal(_ descriptor: Int32) -> Int32
@_silgen_name("unlockpt") fileprivate func glibcUnlockPseudoTerminal(_ descriptor: Int32) -> Int32
@_silgen_name("ptsname") fileprivate func glibcPseudoTerminalName(_ descriptor: Int32) -> UnsafeMutablePointer<CChar>?
#endif

/// The system calls the pseudo-terminal needs, under names that cannot be mistaken for its own
/// `read`, `write` and `close`.
private enum PseudoTerminalSystem {
    /// `ptsname` answers a buffer it owns, so concurrent callers take turns.
    private static let nameLock = NSLock()

    static func openController(_ flags: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.posix_openpt(flags)
        #else
        return glibcOpenPseudoTerminal(flags)
        #endif
    }

    static func grant(_ descriptor: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.grantpt(descriptor)
        #else
        return glibcGrantPseudoTerminal(descriptor)
        #endif
    }

    static func unlock(_ descriptor: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.unlockpt(descriptor)
        #else
        return glibcUnlockPseudoTerminal(descriptor)
        #endif
    }

    static func deviceName(of descriptor: Int32) -> String? {
        nameLock.lock()
        defer { nameLock.unlock() }
        #if canImport(Darwin)
        guard let name = Darwin.ptsname(descriptor) else {
            return nil
        }
        #else
        guard let name = glibcPseudoTerminalName(descriptor) else {
            return nil
        }
        #endif
        return String(cString: name)
    }

    static func makeNonBlocking(_ descriptor: Int32) {
        #if canImport(Darwin)
        _ = Darwin.fcntl(descriptor, F_SETFL, O_NONBLOCK)
        #else
        _ = Glibc.fcntl(descriptor, F_SETFL, O_NONBLOCK)
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

    /// Waits up to `milliseconds` for `events` on `descriptor`. Answers the events that happened
    /// (which may include `POLLHUP`, `POLLERR` or `POLLNVAL`), or 0 when the time ran out.
    static func poll(_ descriptor: Int32, events: Int16, milliseconds: Int32) -> Int16 {
        var request = pollfd(fd: descriptor, events: events, revents: 0)
        while true {
            #if canImport(Darwin)
            let result = Darwin.poll(&request, nfds_t(1), milliseconds)
            #else
            let result = Glibc.poll(&request, nfds_t(1), milliseconds)
            #endif
            if result < 0 {
                if errno == EINTR {
                    continue
                }
                return Int16(POLLERR)
            }
            return result == 0 ? 0 : request.revents
        }
    }
}

/// A pseudo-terminal pair: ``devicePath`` is a terminal device a ``PosixSerialPort`` can open, and
/// this object is the device on its other end — what the port writes, it reads, and the other way
/// round. A serial port test that needs no hardware.
///
/// Closing it hangs up the device side, which a port reading there sees as its device going away.
public final class PseudoTerminal {
    /// The terminal device to open: `/dev/pts/3` on Linux, `/dev/ttys004` on macOS.
    public let devicePath: String

    /// How long one wait lasts at most, so a `close()` from another thread is noticed.
    private static let waitSlice: Int32 = 50
    /// How long a write waits for a port that is not reading before it gives up.
    private static let writeStallMilliseconds = 10_000
    private static let readChunkSize = 4096

    private let lock = NSLock()
    /// The controller side, or -1 once closed. Read and written only with `lock` held.
    private var controller: Int32

    /// Opens a new pair.
    public init() throws {
        let descriptor = PseudoTerminalSystem.openController(O_RDWR | O_NOCTTY)
        if descriptor < 0 {
            throw SerialStreamError.openFailed(path: "/dev/ptmx", code: errno)
        }
        if PseudoTerminalSystem.grant(descriptor) != 0 || PseudoTerminalSystem.unlock(descriptor) != 0 {
            let code = errno
            _ = PseudoTerminalSystem.close(descriptor)
            throw SerialStreamError.openFailed(path: "/dev/ptmx", code: code)
        }
        guard let name = PseudoTerminalSystem.deviceName(of: descriptor) else {
            let code = errno
            _ = PseudoTerminalSystem.close(descriptor)
            throw SerialStreamError.openFailed(path: "/dev/ptmx", code: code)
        }
        // Reads and writes never block, so `close()` is never stuck behind one.
        PseudoTerminalSystem.makeNonBlocking(descriptor)
        self.devicePath = name
        self.controller = descriptor
    }

    deinit {
        self.close()
    }

    /// Sends `bytes` to the port.
    public func write(_ bytes: Data) throws {
        if bytes.isEmpty {
            return
        }
        var offset = 0
        var waitedMilliseconds = 0
        while offset < bytes.count {
            let attempt = self.writeChunk(bytes, from: offset)
            if attempt.count > 0 {
                offset += attempt.count
                waitedMilliseconds = 0
                continue
            }
            switch attempt.code {
            case EBADF:
                throw SerialStreamError.writeFailed(code: EBADF)
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK, 0:
                // Nobody is reading yet: wait for room.
                if waitedMilliseconds >= PseudoTerminal.writeStallMilliseconds {
                    throw SerialStreamError.writeFailed(code: EAGAIN)
                }
                _ = self.wait(for: Int16(POLLOUT), milliseconds: PseudoTerminal.waitSlice)
                waitedMilliseconds += Int(PseudoTerminal.waitSlice)
            default:
                throw SerialStreamError.writeFailed(code: attempt.code)
            }
        }
    }

    /// What the port sent within `timeout`: everything that arrives until nothing more comes for
    /// `timeout`, or an empty `Data` when nothing did.
    public func read(timeout: TimeInterval) -> Data {
        var collected = Data()
        let milliseconds = PseudoTerminal.milliseconds(for: timeout)
        while true {
            let events = self.wait(for: Int16(POLLIN), milliseconds: milliseconds)
            // A timeout, a hang-up with nothing left to read, an error or a closed controller.
            if events & Int16(POLLIN) == 0 {
                return collected
            }
            switch self.readChunk(limit: PseudoTerminal.readChunkSize) {
            case .data(let chunk):
                collected.append(chunk)
            case .retry:
                continue
            case .finished:
                return collected
            }
        }
    }

    /// Exactly `count` bytes from the port, or `nil` when they did not all arrive within `timeout`.
    public func read(count: Int, timeout: TimeInterval) -> Data? {
        if count <= 0 {
            return Data()
        }
        let limit = max(0, min(timeout, 86_400))
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(limit * 1_000_000_000)
        var collected = Data()
        while collected.count < count {
            let now = DispatchTime.now().uptimeNanoseconds
            let remaining = deadline > now ? deadline - now : 0
            let milliseconds = Int32(min((remaining + 999_999) / 1_000_000, UInt64(Int32.max)))
            let events = self.wait(for: Int16(POLLIN), milliseconds: milliseconds)
            if events & Int16(POLLIN) == 0 {
                return nil
            }
            // Never take more than was asked for: the rest stays for the next read.
            switch self.readChunk(limit: min(PseudoTerminal.readChunkSize, count - collected.count)) {
            case .data(let chunk):
                collected.append(chunk)
            case .retry:
                continue
            case .finished:
                return nil
            }
        }
        return collected
    }

    /// Hangs up: closes this end. Safe to call twice.
    public func close() {
        self.lock.lock()
        let descriptor = self.controller
        self.controller = -1
        self.lock.unlock()
        if descriptor >= 0 {
            _ = PseudoTerminalSystem.close(descriptor)
        }
    }
}

// MARK: - Helpers

extension PseudoTerminal {
    private enum Chunk {
        case data(Data)
        case retry
        case finished
    }

    private static func milliseconds(for timeout: TimeInterval) -> Int32 {
        let milliseconds = (max(0, timeout) * 1000).rounded(.up)
        return Int32(min(milliseconds, Double(Int32.max)))
    }

    private func currentController() -> Int32 {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.controller
    }

    /// Waits up to `milliseconds` for `events` on the controller, a slice at a time so that a
    /// `close()` is noticed. Answers the events that happened, 0 when the time ran out, or `POLLNVAL`
    /// when the controller is closed.
    private func wait(for events: Int16, milliseconds: Int32) -> Int16 {
        var remaining = milliseconds
        while true {
            let descriptor = self.currentController()
            if descriptor < 0 {
                return Int16(POLLNVAL)
            }
            let slice = min(remaining, PseudoTerminal.waitSlice)
            let happened = PseudoTerminalSystem.poll(descriptor, events: events, milliseconds: slice)
            if happened != 0 {
                return happened
            }
            remaining -= slice
            if remaining <= 0 {
                return 0
            }
        }
    }

    /// One non-blocking write of what is left of `bytes` from `offset`: the bytes taken, and the
    /// `errno` when none were.
    private func writeChunk(_ bytes: Data, from offset: Int) -> (count: Int, code: Int32) {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.controller < 0 {
            return (0, EBADF)
        }
        let descriptor = self.controller
        return bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (count: Int, code: Int32) in
            guard let base = raw.baseAddress else {
                return (0, 0)
            }
            let count = PseudoTerminalSystem.write(descriptor, base + offset, raw.count - offset)
            return (max(count, 0), count < 0 ? errno : 0)
        }
    }

    /// One non-blocking read of at most `limit` bytes.
    private func readChunk(limit: Int) -> Chunk {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.controller < 0 {
            return .finished
        }
        let descriptor = self.controller
        var buffer = [UInt8](repeating: 0, count: limit)
        let result = buffer.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> (count: Int, code: Int32) in
            let count = PseudoTerminalSystem.read(descriptor, bytes.baseAddress, bytes.count)
            return (count, count < 0 ? errno : 0)
        }
        if result.count > 0 {
            return .data(Data(buffer[0..<result.count]))
        }
        if result.count == 0 {
            return .finished
        }
        if result.code == EINTR || result.code == EAGAIN || result.code == EWOULDBLOCK {
            return .retry
        }
        // On Linux a read fails with EIO while nobody has the device side open.
        return .finished
    }
}
