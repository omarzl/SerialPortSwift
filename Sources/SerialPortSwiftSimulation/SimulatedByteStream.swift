//
//  SimulatedByteStream.swift
//  SerialPortSwiftSimulation
//

import Foundation
import SerialPortSwift

/// A device in software: it answers each frame written to it.
public protocol SerialDeviceSimulator: AnyObject {
    /// The reply to `frame`, or `nil` when the device says nothing. Called on the stream's queue,
    /// once per write, in order.
    func reply(to frame: Data) -> Data?
}

/// A ``SerialByteStream`` whose other end is a ``SerialDeviceSimulator``.
///
/// Every `write(_:)` is one frame: the device is asked for its reply at once, on the stream's queue,
/// and the reply arrives ``replyLatency`` later as one chunk. Faults can be injected to rehearse a bad
/// wire: a reply that never comes, filler bytes in front of every reply, the device being unplugged.
///
/// Open, close and ``simulateRemoval()`` report synchronously, before they return.
public final class SimulatedByteStream: SerialByteStream {
    public let name: String
    public let device: SerialDeviceSimulator
    public weak var delegate: SerialByteStreamDelegate?

    /// A reply waiting for its time. `due` is in `DispatchTime` uptime nanoseconds.
    private struct PendingReply {
        let due: UInt64
        let payload: Data
    }

    private let queue: DispatchQueue

    // Everything below is guarded by `lock`, which is never held while calling the delegate or the device.
    private let lock = NSLock()
    private var opened = false
    private var generation = 0
    private var latency: TimeInterval
    private var fillerCount = 0
    private var filler: UInt8 = 0xFF
    private var dropArmed = false
    /// Replies on their way, oldest first. A reply is never delivered before the ones in front of it.
    private var pending: [PendingReply] = []

    public init(
        name: String = "simulated",
        device: SerialDeviceSimulator,
        replyLatency: TimeInterval = 0.001,
        queue: DispatchQueue? = nil
    ) {
        self.name = name
        self.device = device
        self.latency = replyLatency
        self.queue = queue ?? DispatchQueue(label: "SerialPortSwift.SimulatedByteStream.\(name)")
    }

    public var isOpen: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.opened
    }

    /// How long a reply takes to arrive. Applies to replies to later writes.
    public var replyLatency: TimeInterval {
        get {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.latency
        }
        set {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.latency = newValue
        }
    }

    /// How many ``fillerByte``s are put in front of every reply. `0` for none.
    public var fillerByteCount: Int {
        get {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.fillerCount
        }
        set {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.fillerCount = max(0, newValue)
        }
    }

    /// The filler byte. `0xFF` by default.
    public var fillerByte: UInt8 {
        get {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.filler
        }
        set {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.filler = newValue
        }
    }

    /// Drops the next reply the device gives, so whoever waits for it times out. Writes the device does
    /// not answer do not use it up.
    public func dropNextReply() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.dropArmed = true
    }

    /// Whether the next reply will be dropped.
    public var isDropArmed: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.dropArmed
    }

    /// The device is unplugged: the stream closes with ``SerialCloseReason/removed`` and replies still
    /// on their way are lost. `open()` plugs it back in.
    public func simulateRemoval() {
        self.closeStream(reason: .removed)
    }

    public func open() {
        self.lock.lock()
        if self.opened {
            self.lock.unlock()
            return
        }
        self.opened = true
        self.generation += 1
        self.lock.unlock()

        self.delegate?.streamDidOpen(self)
    }

    public func close() {
        self.closeStream(reason: .requested)
    }

    public func write(_ bytes: Data) {
        self.queue.async {
            self.handleWrite(bytes)
        }
    }

    // MARK: - Closing

    private func closeStream(reason: SerialCloseReason) {
        self.lock.lock()
        if !self.opened {
            self.lock.unlock()
            return
        }
        self.opened = false
        self.generation += 1
        self.pending.removeAll()
        self.lock.unlock()

        self.delegate?.streamDidClose(self, reason: reason)
    }

    // MARK: - Writes and replies

    /// Runs on `queue`.
    private func handleWrite(_ bytes: Data) {
        self.lock.lock()
        if !self.opened {
            self.lock.unlock()
            return
        }
        let writeGeneration = self.generation
        self.lock.unlock()

        guard let reply = self.device.reply(to: bytes) else {
            return
        }

        self.lock.lock()
        if self.generation != writeGeneration {
            // The stream closed while the device was thinking: the reply is lost.
            self.lock.unlock()
            return
        }
        if self.dropArmed {
            self.dropArmed = false
            self.lock.unlock()
            return
        }
        var payload = Data(repeating: self.filler, count: self.fillerCount)
        payload.append(reply)
        let due = (DispatchTime.now() + max(0, self.latency)).uptimeNanoseconds
        let isHead = self.pending.isEmpty
        if !payload.isEmpty {
            self.pending.append(PendingReply(due: due, payload: payload))
        }
        self.lock.unlock()

        if isHead && !payload.isEmpty {
            self.scheduleDelivery(at: due)
        }
    }

    /// Wakes up at `due` to deliver whatever is ready. Every reply that becomes the oldest one gets a
    /// wake-up, so none waits for a wake-up that is not coming. A wake-up left over from a stream that
    /// has been closed since finds nothing due and does nothing.
    private func scheduleDelivery(at due: UInt64) {
        self.queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: due)) {
            self.deliverReadyReplies()
        }
    }

    /// Runs on `queue`: delivers the replies whose time has come, oldest first.
    private func deliverReadyReplies() {
        while true {
            self.lock.lock()
            guard let oldest = self.pending.first else {
                self.lock.unlock()
                return
            }
            if oldest.due > DispatchTime.now().uptimeNanoseconds {
                self.lock.unlock()
                self.scheduleDelivery(at: oldest.due)
                return
            }
            self.pending.removeFirst()
            self.lock.unlock()

            self.delegate?.stream(self, didReceive: oldest.payload)
        }
    }
}
