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

    private var windows: [Key: RoundTripWindow] = [:]

    public init(windowSize: Int = 1000) {
        self.windowSize = windowSize
    }

    public mutating func record(_ roundTrip: TimeInterval, for key: Key) {
        windows[key, default: RoundTripWindow()].append(roundTrip, keeping: max(1, windowSize))
    }

    /// The summary of `key`'s window, or `nil` when nothing was recorded for it.
    public func summary(for key: Key) -> RoundTripSummary? {
        guard let window = windows[key], !window.values.isEmpty else {
            return nil
        }
        let sorted = window.values.sorted()
        return RoundTripSummary(
            count: sorted.count,
            total: window.total,
            median: RoundTripWindow.nearestRank(0.5, in: sorted),
            p99: RoundTripWindow.nearestRank(0.99, in: sorted)
        )
    }

    /// Every key with at least one round trip recorded.
    public var keys: [Key] {
        return Array(windows.keys)
    }

    public mutating func reset() {
        windows.removeAll()
    }
}

/// The most recent values of one key, in a ring, and how many were ever recorded.
private struct RoundTripWindow {
    private(set) var values: [TimeInterval] = []
    private(set) var total = 0
    private var oldest = 0

    mutating func append(_ value: TimeInterval, keeping capacity: Int) {
        total += 1
        if values.count < capacity {
            values.append(value)
        } else {
            values[oldest] = value
            oldest = (oldest + 1) % capacity
        }
    }

    /// The value at rank ⌈`fraction` × n⌉ of the `n` sorted values.
    static func nearestRank(_ fraction: Double, in sorted: [TimeInterval]) -> TimeInterval {
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}
