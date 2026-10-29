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

    public init(
        name: String = "simulated",
        device: SerialDeviceSimulator,
        replyLatency: TimeInterval = 0.001,
        queue: DispatchQueue? = nil
    ) {
        self.name = name
        self.device = device
        fatalError("Not implemented yet")
    }

    public var isOpen: Bool {
        fatalError("Not implemented yet")
    }

    /// How long a reply takes to arrive. Applies to replies to later writes.
    public var replyLatency: TimeInterval {
        get { fatalError("Not implemented yet") }
        set { fatalError("Not implemented yet") }
    }

    /// How many ``fillerByte``s are put in front of every reply. `0` for none.
    public var fillerByteCount: Int {
        get { fatalError("Not implemented yet") }
        set { fatalError("Not implemented yet") }
    }

    /// The filler byte. `0xFF` by default.
    public var fillerByte: UInt8 {
        get { fatalError("Not implemented yet") }
        set { fatalError("Not implemented yet") }
    }

    /// Drops the next reply the device gives, so whoever waits for it times out. Writes the device
    /// does not answer do not use it up.
    public func dropNextReply() {
        fatalError("Not implemented yet")
    }

    /// Whether the next reply will be dropped.
    public var isDropArmed: Bool {
        fatalError("Not implemented yet")
    }

    /// The device is unplugged: the stream closes with ``SerialCloseReason/removed`` and replies still
    /// on their way are lost. `open()` plugs it back in.
    public func simulateRemoval() {
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
}
