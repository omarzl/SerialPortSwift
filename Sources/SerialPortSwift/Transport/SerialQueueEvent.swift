//
//  SerialQueueEvent.swift
//  SerialPortSwift
//

import Foundation

/// One thing that happened on a ``SerialRequestQueue``, for whoever watches its traffic: a console,
/// a recorder, a log.
public struct SerialQueueEvent: Equatable {
    public enum Kind: Equatable {
        case opened
        case closed(SerialCloseReason)
        /// Bytes reached the stream: an exchange's frame, or a write without a reply (`nil`).
        /// `bytes` is what was written.
        case sent(SerialExchangeID?)
        /// A chunk the stream delivered, exactly as received, before anything decides what it is.
        case raw
        /// An exchange was answered. `bytes` is the reply; `roundTrip` runs from handing the frame to
        /// the stream to the reply's last byte.
        case answered(SerialExchangeID, roundTrip: TimeInterval)
        /// An exchange's reply did not arrive in time. `bytes` is the frame that was sent.
        case timedOut(SerialExchangeID)
        /// The matcher found bytes it cannot read while waiting for this exchange. `bytes` is the
        /// longest unreadable candidate; at most one per scan.
        case unreadableCandidate(SerialExchangeID)
        /// Bytes that arrived during the pause after a timeout, too late for the exchange that timed
        /// out. Dropped rather than credited to the next one.
        case lateBytesDropped
        /// Bytes that arrived with no exchange on the wire. Dropped.
        case unsolicitedBytesDropped
        /// Exchanges dropped from the queue by ``SerialRequestQueue/cancelQueuedExchanges()``.
        case cancelled([SerialExchangeID])
    }

    /// When it happened, by the wall clock.
    public let date: Date
    public let kind: Kind
    /// The bytes involved, as each kind describes; `nil` when there are none.
    public let bytes: Data?

    public init(date: Date = Date(), kind: Kind, bytes: Data? = nil) {
        self.date = date
        self.kind = kind
        self.bytes = bytes
    }
}

/// Watches a ``SerialRequestQueue``'s traffic.
///
/// Called on the queue's own serial queue, synchronously and in order, so keep it quick and hand
/// anything slow to another queue. Observers are held weakly.
public protocol SerialQueueObserver: AnyObject {
    func requestQueue(_ queue: SerialRequestQueue, didLog event: SerialQueueEvent)
}

// `Sendable` is a marker with nothing at run time; a compiler older than 5.5 does not know it. The types
// that carry `Data` or `Date` say `@unchecked`: Foundation on Linux does not mark those `Sendable` in older
// toolchains, which then refuse (5.5, 5.6) or warn about (5.7 and later ones) a plain conformance.
#if compiler(>=5.5)
    extension SerialQueueEvent: @unchecked Sendable {}
    extension SerialQueueEvent.Kind: Sendable {}
#endif
