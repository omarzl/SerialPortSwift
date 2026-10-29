//
//  RoundTripStatistics.swift
//  SerialPortSwift
//

import Foundation

/// The median and 99th percentile of a window of round trips.
public struct RoundTripSummary: Equatable {
    /// Round trips in the window.
    public let count: Int
    /// Round trips ever recorded for this key, the window included.
    public let total: Int
    public let median: TimeInterval
    public let p99: TimeInterval

    public init(count: Int, total: Int, median: TimeInterval, p99: TimeInterval) {
        self.count = count
        self.total = total
        self.median = median
        self.p99 = p99
    }
}

/// Round-trip times kept per key — per device, per command, whatever the caller groups by — over a
/// window of the most recent ones. Percentiles use the nearest-rank method: the *p*-th percentile of
/// *n* sorted values is the value at rank ⌈*p* × *n*⌉.
///
/// A value type with no locking: keep it on one thread.
public struct RoundTripStatistics<Key: Hashable> {
    /// How many of the most recent round trips each key keeps.
    public let windowSize: Int

    public init(windowSize: Int = 1000) {
        self.windowSize = windowSize
    }

    public mutating func record(_ roundTrip: TimeInterval, for key: Key) {
        fatalError("Not implemented yet")
    }

    /// The summary of `key`'s window, or `nil` when nothing was recorded for it.
    public func summary(for key: Key) -> RoundTripSummary? {
        fatalError("Not implemented yet")
    }

    /// Every key with at least one round trip recorded.
    public var keys: [Key] {
        fatalError("Not implemented yet")
    }

    public mutating func reset() {
        fatalError("Not implemented yet")
    }
}
