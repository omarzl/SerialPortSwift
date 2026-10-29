//
//  RoundTripStatisticsTests.swift
//  SerialPortSwiftTests
//

import SerialPortSwift
import XCTest

final class RoundTripStatisticsTests: XCTestCase {
    func testAHundredValuesGiveTheNearestRankMedianAndP99() {
        var statistics = RoundTripStatistics<String>()
        for value in 1...100 {
            statistics.record(TimeInterval(value), for: "read")
        }

        let summary = statistics.summary(for: "read")

        XCTAssertEqual(summary, RoundTripSummary(count: 100, total: 100, median: 50, p99: 99))
    }

    func testTheOrderOfRecordingDoesNotMatter() {
        var statistics = RoundTripStatistics<String>()
        for value in (1...100).reversed() {
            statistics.record(TimeInterval(value), for: "read")
        }

        XCTAssertEqual(statistics.summary(for: "read")?.median, 50)
        XCTAssertEqual(statistics.summary(for: "read")?.p99, 99)
    }

    func testASingleValueIsBothPercentiles() {
        var statistics = RoundTripStatistics<String>()
        statistics.record(0.25, for: "read")

        XCTAssertEqual(statistics.summary(for: "read"), RoundTripSummary(count: 1, total: 1, median: 0.25, p99: 0.25))
    }

    func testTwoValuesRankByCeiling() {
        var statistics = RoundTripStatistics<String>()
        statistics.record(2, for: "read")
        statistics.record(1, for: "read")

        // Rank ceil(0.5 * 2) = 1 and ceil(0.99 * 2) = 2.
        XCTAssertEqual(statistics.summary(for: "read")?.median, 1)
        XCTAssertEqual(statistics.summary(for: "read")?.p99, 2)
    }

    func testAnOddCountPicksTheMiddleValue() {
        var statistics = RoundTripStatistics<String>()
        for value in [5.0, 1.0, 3.0] {
            statistics.record(value, for: "read")
        }

        // Rank ceil(0.5 * 3) = 2.
        XCTAssertEqual(statistics.summary(for: "read")?.median, 3)
    }

    func testTheWindowKeepsOnlyTheLatestValuesButTheTotalKeepsCounting() {
        var statistics = RoundTripStatistics<String>(windowSize: 10)
        for value in 1...25 {
            statistics.record(TimeInterval(value), for: "read")
        }

        let summary = statistics.summary(for: "read")

        // The window holds 16...25: the median is the 5th of them and the p99 the last.
        XCTAssertEqual(summary, RoundTripSummary(count: 10, total: 25, median: 20, p99: 25))
    }

    func testTheWindowForgetsAHugeValueOnceItScrolledOut() {
        var statistics = RoundTripStatistics<String>(windowSize: 3)
        statistics.record(1000, for: "read")
        for _ in 0..<3 {
            statistics.record(1, for: "read")
        }

        XCTAssertEqual(statistics.summary(for: "read"), RoundTripSummary(count: 3, total: 4, median: 1, p99: 1))
    }

    func testAWindowOfOneKeepsTheLastValue() {
        var statistics = RoundTripStatistics<String>(windowSize: 1)
        statistics.record(1, for: "read")
        statistics.record(2, for: "read")

        XCTAssertEqual(statistics.summary(for: "read"), RoundTripSummary(count: 1, total: 2, median: 2, p99: 2))
    }

    func testKeysAreKeptApart() {
        var statistics = RoundTripStatistics<String>()
        statistics.record(1, for: "read")
        statistics.record(9, for: "write")

        XCTAssertEqual(statistics.summary(for: "read")?.median, 1)
        XCTAssertEqual(statistics.summary(for: "write")?.median, 9)
        XCTAssertEqual(Set(statistics.keys), ["read", "write"])
    }

    func testAnUnknownKeyHasNoSummary() {
        var statistics = RoundTripStatistics<String>()
        statistics.record(1, for: "read")

        XCTAssertNil(statistics.summary(for: "other"))
        XCTAssertNil(RoundTripStatistics<Int>().summary(for: 1))
        XCTAssertEqual(RoundTripStatistics<Int>().keys, [])
    }

    func testResetEmptiesEverything() {
        var statistics = RoundTripStatistics<String>()
        statistics.record(1, for: "read")
        statistics.record(2, for: "write")

        statistics.reset()

        XCTAssertNil(statistics.summary(for: "read"))
        XCTAssertEqual(statistics.keys, [])

        statistics.record(3, for: "read")
        XCTAssertEqual(statistics.summary(for: "read"), RoundTripSummary(count: 1, total: 1, median: 3, p99: 3))
    }

    func testAnyHashableTypeCanBeAKey() {
        var statistics = RoundTripStatistics<SerialExchangeID>()
        statistics.record(0.5, for: SerialExchangeID(number: 7))

        XCTAssertEqual(statistics.summary(for: SerialExchangeID(number: 7))?.count, 1)
    }
}
