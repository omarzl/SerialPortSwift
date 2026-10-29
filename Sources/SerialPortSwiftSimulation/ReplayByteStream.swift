//
//  ReplayByteStream.swift
//  SerialPortSwiftSimulation
//

import Foundation
import SerialPortSwift

/// Bytes a ``ReplayByteStream`` delivers, and when: `offset` seconds after the moment it is measured
/// from.
public struct ReplayChunk: Equatable {
    public let bytes: Data
    public let offset: TimeInterval

    public init(_ bytes: Data, at offset: TimeInterval = 0) {
        self.bytes = bytes
        self.offset = offset
    }
}

/// One step of a replay script: the next write, and what the device answers to it.
public struct ReplayStep: Equatable {
    /// What the write should be, or `nil` to accept any.
    public let expected: Data?
    /// The chunks delivered after that write, each at its offset from the moment of the write.
    public let replies: [ReplayChunk]

    public init(expecting expected: Data? = nil, replies: [ReplayChunk]) {
        self.expected = expected
        self.replies = replies
    }

    /// The next write is answered with `chunks`.
    public static func reply(to expected: Data? = nil, with chunks: [ReplayChunk]) -> ReplayStep {
        return ReplayStep(expecting: expected, replies: chunks)
    }

    /// The next write gets no answer.
    public static func silence(after expected: Data? = nil) -> ReplayStep {
        return ReplayStep(expecting: expected, replies: [])
    }
}

/// A write a ``ReplayByteStream`` received.
public struct ReplayWrite: Equatable {
    public let date: Date
    public let bytes: Data
    /// Whether a script step was waiting for it and its bytes were the ones expected. A write that
    /// arrives with the script used up, or that differs from the step's `expected`, is `false`.
    public let matchedExpectation: Bool

    public init(date: Date, bytes: Data, matchedExpectation: Bool) {
        self.date = date
        self.bytes = bytes
        self.matchedExpectation = matchedExpectation
    }
}

/// A ``SerialByteStream`` that plays a script: recorded or written-by-hand traffic, with its timing.
/// Built for driving a ``SerialRequestQueue`` in tests.
///
/// Each write uses up the next ``ReplayStep``, whose replies are then delivered at their offsets from
/// that write — even while an earlier step's replies are still on their way. A write that arrives
/// with the script used up is recorded and gets no answer. Bytes and closes the script does not tie
/// to a write are pushed with ``receive(_:after:)`` and ``end(_:after:)``.
///
/// Open and close report synchronously, before they return.
public final class ReplayByteStream: SerialByteStream {
    public let name: String
    public weak var delegate: SerialByteStreamDelegate?

    /// - Parameters:
    ///   - openFailure: when set, `open()` fails with it instead of opening.
    public init(
        name: String = "replay",
        script: [ReplayStep] = [],
        openFailure: SerialStreamError? = nil,
        queue: DispatchQueue? = nil
    ) {
        self.name = name
        fatalError("Not implemented yet")
    }

    public var isOpen: Bool {
        fatalError("Not implemented yet")
    }

    /// Adds steps at the end of the script.
    public func append(_ steps: [ReplayStep]) {
        fatalError("Not implemented yet")
    }

    /// Delivers `bytes` `delay` seconds from now, as one chunk, whatever the script says. Ignored if
    /// the stream is closed by then.
    public func receive(_ bytes: Data, after delay: TimeInterval = 0) {
        fatalError("Not implemented yet")
    }

    /// Closes the stream `delay` seconds from now, as if the device did it: reported with `reason`.
    public func end(_ reason: SerialCloseReason, after delay: TimeInterval = 0) {
        fatalError("Not implemented yet")
    }

    /// Every write so far, in order.
    public var writes: [ReplayWrite] {
        fatalError("Not implemented yet")
    }

    /// Steps not yet used up by a write.
    public var remainingSteps: Int {
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
