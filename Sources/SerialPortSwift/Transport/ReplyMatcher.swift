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
    /// What `candidate` is. The default ``scan(_:expecting:)`` passes a slice of the buffer rather than
    /// a copy, so `candidate.startIndex` need not be `0`: iterate it, or count from its `startIndex`.
    func verdict(on candidate: Data, expecting shape: ReplyShape) -> ReplyVerdict
    func scan(_ buffer: Data, expecting shape: ReplyShape) -> ReplyScan
}

extension ReplyMatcher {
    /// Tries `buffer`'s tails from the shortest (its last byte) to the longest (all of it) and answers
    /// the first one ``verdict(on:expecting:)`` accepts, raw. Called after every byte received, so a
    /// reply is found as soon as its last byte arrives.
    ///
    /// The tails are handed to ``verdict(on:expecting:)`` as slices of `buffer`, without copying; the
    /// packet and the unreadable candidate in the result are fresh `Data` that start at `0`.
    public func scan(_ buffer: Data, expecting shape: ReplyShape) -> ReplyScan {
        var longestUnreadable: Data?
        var length = 1
        while length <= buffer.count {
            let tail = buffer.suffix(length)
            switch verdict(on: tail, expecting: shape) {
            case .accepted:
                return ReplyScan(packet: Data(tail), unreadable: longestUnreadable.map { Data($0) })
            case .unreadable:
                longestUnreadable = tail
            case .rejected:
                break
            }
            length += 1
        }
        return ReplyScan(packet: nil, unreadable: longestUnreadable.map { Data($0) })
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
///   `String` counts them (so `"\r\n"` is one character; see ``LengthUnit/characters``).
public struct TailScanMatcher: ReplyMatcher {
    public enum LengthUnit: Equatable {
        case bytes
        /// `Character`s of the candidate decoded as ISO Latin-1 — the same as ASCII for ASCII bytes.
        ///
        /// `"\r\n"` counts as one character, but a ``SerialRequestQueue`` scans after every byte: a
        /// reply that ends in `"\r\n"` is found at its `"\r"`, and the `"\n"` then arrives with
        /// nothing in flight, or with the next exchange. Use `.bytes` for replies that end in `"\r\n"`.
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
        // One pass: count the bytes that are not filler, and stop at one that is not ASCII if ASCII is
        // required.
        var counted = 0
        for byte in candidate where !fillerBytes.contains(byte) {
            if requiresASCII && byte > 0x7F {
                return .unreadable
            }
            counted += 1
        }
        switch shape {
        case .anything:
            return .accepted
        case .exactly(let length):
            return measure(candidate, counting: counted) == length ? .accepted : .rejected
        }
    }

    /// The length of `candidate` without its filler bytes, in the unit asked for. `counted` is how many
    /// bytes that is.
    private func measure(_ candidate: Data, counting counted: Int) -> Int {
        switch lengthUnit {
        case .bytes:
            return counted
        case .characters:
            // Latin-1 maps each byte to the scalar of the same value, on every platform.
            var scalars = String.UnicodeScalarView()
            for byte in candidate where !fillerBytes.contains(byte) {
                scalars.append(Unicode.Scalar(byte))
            }
            return String(scalars).count
        }
    }
}
