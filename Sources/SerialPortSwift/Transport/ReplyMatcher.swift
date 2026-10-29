//
//  ReplyMatcher.swift
//  SerialPortSwift
//

import Foundation

/// What a ``ReplyMatcher`` makes of one candidate reply.
public enum ReplyVerdict: Equatable {
    /// The candidate is the reply.
    case accepted
    /// The candidate is not the reply, or not yet.
    case rejected
    /// The candidate holds bytes the matcher cannot read at all — worth reporting, since a device
    /// that answers in them is out of step with the wire.
    case unreadable
}

/// The result of scanning the bytes received so far for an exchange.
public struct ReplyScan: Equatable {
    /// The reply, raw, exactly as received; `nil` while there is none.
    public let packet: Data?
    /// The longest candidate examined whose verdict was ``ReplyVerdict/unreadable``, if any.
    public let unreadable: Data?

    public init(packet: Data?, unreadable: Data?) {
        self.packet = packet
        self.unreadable = unreadable
    }
}

/// Recognises a reply in the bytes received for an exchange.
///
/// ``verdict(on:expecting:)`` is the rule for one candidate. ``scan(_:expecting:)`` applies it to the
/// buffer; its default implementation tries the buffer's tails from the shortest to the longest
/// after every byte, and the first one accepted is the reply.
public protocol ReplyMatcher {
    func verdict(on candidate: Data, expecting shape: ReplyShape) -> ReplyVerdict
    func scan(_ buffer: Data, expecting shape: ReplyShape) -> ReplyScan
}

extension ReplyMatcher {
    /// Tries `buffer`'s tails from the shortest (its last byte) to the longest (all of it) and answers
    /// the first one ``verdict(on:expecting:)`` accepts, raw. Called after every byte received, so a
    /// reply is found as soon as its last byte arrives.
    public func scan(_ buffer: Data, expecting shape: ReplyShape) -> ReplyScan {
        // Copy to an array first: a `Data` slice keeps its parent's indices, an array does not.
        let bytes = Array(buffer)
        guard !bytes.isEmpty else {
            return ReplyScan(packet: nil, unreadable: nil)
        }
        var longestUnreadable: Data?
        for length in 1...bytes.count {
            let tail = Data(bytes[(bytes.count - length)...])
            switch verdict(on: tail, expecting: shape) {
            case .accepted:
                return ReplyScan(packet: tail, unreadable: longestUnreadable)
            case .unreadable:
                longestUnreadable = tail
            case .rejected:
                break
            }
        }
        return ReplyScan(packet: nil, unreadable: longestUnreadable)
    }
}

/// The matcher most serial devices need: a reply is the last *n* units received, after setting aside
/// the filler bytes some devices pad with.
///
/// - `fillerBytes` are ignored when a candidate is measured, but stay in the reply delivered when
///   they sit inside it. A ``SerialRequestQueue`` scans after every byte, so its replies end at
///   their last counted byte: filler in front of a reply or after it is not part of it.
/// - With `requiresASCII`, a candidate holding any byte above `0x7F` (other than a filler byte) is
///   ``ReplyVerdict/unreadable``.
/// - `lengthUnit` says what ``ReplyShape/exactly(_:)`` counts: bytes, or characters as Swift's
///   `String` counts them (so `"\r\n"` is one character).
public struct TailScanMatcher: ReplyMatcher {
    public enum LengthUnit: Equatable {
        case bytes
        /// `Character`s of the candidate decoded as ISO Latin-1 — the same as ASCII for ASCII bytes.
        case characters
    }

    public let fillerBytes: Set<UInt8>
    public let requiresASCII: Bool
    public let lengthUnit: LengthUnit

    public init(fillerBytes: Set<UInt8> = [], requiresASCII: Bool = false, lengthUnit: LengthUnit = .bytes) {
        self.fillerBytes = fillerBytes
        self.requiresASCII = requiresASCII
        self.lengthUnit = lengthUnit
    }

    public func verdict(on candidate: Data, expecting shape: ReplyShape) -> ReplyVerdict {
        var cleaned = [UInt8]()
        cleaned.reserveCapacity(candidate.count)
        for byte in candidate where !fillerBytes.contains(byte) {
            cleaned.append(byte)
        }
        if requiresASCII {
            for byte in cleaned where byte > 0x7F {
                return .unreadable
            }
        }
        switch shape {
        case .anything:
            return .accepted
        case .exactly(let length):
            return measure(cleaned) == length ? .accepted : .rejected
        }
    }

    private func measure(_ cleaned: [UInt8]) -> Int {
        switch lengthUnit {
        case .bytes:
            return cleaned.count
        case .characters:
            // Latin-1 maps each byte to the scalar of the same value, on every platform.
            var scalars = String.UnicodeScalarView()
            for byte in cleaned {
                scalars.append(Unicode.Scalar(byte))
            }
            return String(scalars).count
        }
    }
}
