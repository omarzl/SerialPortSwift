//
//  SerialByteStream.swift
//  SerialPortSwift
//

import Foundation

/// A two-way stream of bytes: a serial port, a simulated device, or anything else that carries
/// frames — a TCP connection could implement it. It knows nothing about requests and replies;
/// ``SerialRequestQueue`` adds those on top of any stream.
///
/// Set `delegate` before calling `open()`: what a stream reports while it has no delegate is lost.
///
/// Every implementation keeps this threading contract:
///
/// - `open()` and `close()` may report their outcome synchronously, on the caller's thread, before
///   they return. The streams in this package do. A stream that opens asynchronously reports later,
///   on its own queue.
/// - `write(_:)` may be called from any thread, writes the bytes in the order it was given them, and
///   never calls the delegate before it returns: a failed write is reported later, on the stream's
///   own queue.
/// - `stream(_:didReceive:)` is reported on the stream's own queue, in order. So is a close the
///   stream did not ask for (`.removed`, `.failed`), unless it is the direct result of a call, as
///   when a simulated device is unplugged: that close may be reported synchronously from the call
///   that caused it.
/// - Opening an open stream, or closing a closed one, does nothing and reports nothing; closing a
///   stream that is not open yet reports nothing either. Writing to a closed stream does nothing.
public protocol SerialByteStream: AnyObject {
    /// A short name for logs and for people: `usbserial-1420`, `simulated`.
    var name: String { get }
    var delegate: SerialByteStreamDelegate? { get set }
    func open()
    func close()
    func write(_ bytes: Data)
}

/// What a ``SerialByteStream`` tells its owner.
public protocol SerialByteStreamDelegate: AnyObject {
    func streamDidOpen(_ stream: SerialByteStream)
    /// Bytes as the device sent them, one chunk per read: a chunk is not a message.
    func stream(_ stream: SerialByteStream, didReceive bytes: Data)
    /// The stream is closed: on request, because the device went away, or because it failed —
    /// including a failure to open.
    func streamDidClose(_ stream: SerialByteStream, reason: SerialCloseReason)
}
