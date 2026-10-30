//
//  SerialTransport.swift
//  SerialPortSwift
//

import Foundation

/// Names one exchange, so its answer finds its way back to whoever asked. The caller picks the
/// number; the transport only carries it.
public struct SerialExchangeID: Hashable {
    public let number: Int

    public init(number: Int) {
        self.number = number
    }
}

/// How a reply is recognised.
public enum ReplyShape: Equatable {
    /// Exactly this many units, as the ``ReplyMatcher`` counts them.
    case exactly(Int)
    /// The first byte that arrives.
    case anything
}

/// One request that expects a reply.
public struct SerialExchange {
    public let id: SerialExchangeID
    /// The bytes written to the device.
    public let frame: Data
    /// What the reply looks like.
    public let reply: ReplyShape
    /// How long to wait for the reply, or `nil` for the transport's ``SerialTransport/defaultTimeout``.
    /// The time runs from the moment the frame is handed to the stream, so it includes any time the
    /// stream takes to get earlier bytes out.
    public let timeout: TimeInterval?

    public init(id: SerialExchangeID, frame: Data, reply: ReplyShape, timeout: TimeInterval? = nil) {
        self.id = id
        self.frame = frame
        self.reply = reply
        self.timeout = timeout
    }
}

/// A request/response channel to a device: one exchange on the wire at a time, the rest waiting
/// their turn in order.
///
/// ``SerialRequestQueue`` implements it over any ``SerialByteStream``. Another implementation can wrap
/// a different driver, so an app talks to one protocol whichever driver is behind it.
///
/// Delegate calls arrive on the transport's delivery queue (the main queue unless configured
/// otherwise). Set `delegate` before calling `open()`: what the transport reports while it has no
/// delegate is lost.
public protocol SerialTransport: AnyObject {
    var name: String { get }
    var isOpen: Bool { get }
    /// The timeout of an exchange that does not carry its own.
    var defaultTimeout: TimeInterval { get }
    var delegate: SerialTransportDelegate? { get set }
    func open()
    func close()
    /// Queues a request that expects a reply. Its outcome — answered or timed out — reaches the
    /// delegate. On a closed transport nothing is written and nothing is reported.
    func send(_ exchange: SerialExchange)
    /// Queues bytes that expect no reply. They wait their turn behind everything queued before them,
    /// exchanges included, so the device sees every write in the order it was asked for.
    func sendWithoutReply(_ frame: Data)
    /// Drops the exchanges still waiting their turn and answers which ones they were. The exchange
    /// already on the wire is left to its reply or its timeout, and writes without a reply stay
    /// queued. Nothing is reported to the delegate for the dropped exchanges.
    func cancelQueuedExchanges() -> [SerialExchangeID]
}

/// What a ``SerialTransport`` tells its owner.
public protocol SerialTransportDelegate: AnyObject {
    func transportDidOpen(_ transport: SerialTransport)
    /// The transport closed. Exchanges still waiting, and the one on the wire, will not be answered.
    func transportDidClose(_ transport: SerialTransport, reason: SerialCloseReason)
    /// `reply` is the raw bytes that satisfied the exchange's ``ReplyShape``, exactly as received.
    func transport(_ transport: SerialTransport, didAnswer exchange: SerialExchange, with reply: Data)
    func transport(_ transport: SerialTransport, didTimeOut exchange: SerialExchange)
    /// A problem the transport survived: it is still open. A transport that wraps another driver
    /// uses it to pass on that driver's errors; ``SerialRequestQueue`` never calls it. Optional:
    /// the default implementation does nothing.
    func transport(_ transport: SerialTransport, didEncounter error: SerialStreamError)
}

extension SerialTransportDelegate {
    public func transport(_ transport: SerialTransport, didEncounter error: SerialStreamError) {}
}

// `Sendable` is a marker with nothing at run time; a compiler older than 5.5 does not know it.
#if compiler(>=5.5)
    extension SerialExchangeID: Sendable {}
    extension ReplyShape: Sendable {}
    extension SerialExchange: Sendable {}
#endif
