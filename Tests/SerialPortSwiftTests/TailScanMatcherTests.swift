//
//  TailScanMatcherTests.swift
//  SerialPortSwiftTests
//

import SerialPortSwift
import XCTest

final class TailScanMatcherTests: XCTestCase {
    private let filler: UInt8 = 0xFF

    /// The matcher a filler-padding device needs: 0xFF is ignored, replies are ASCII and counted in
    /// characters.
    private var padded: TailScanMatcher {
        return TailScanMatcher(fillerBytes: [0xFF], requiresASCII: true, lengthUnit: .characters)
    }

    private func data(_ string: String) -> Data {
        return Data(string.utf8)
    }

    // MARK: - verdict

    func testExactlyCountsBytes() {
        let matcher = TailScanMatcher()

        XCTAssertEqual(matcher.verdict(on: Data([1, 2, 3]), expecting: .exactly(3)), .accepted)
        XCTAssertEqual(matcher.verdict(on: Data([1, 2]), expecting: .exactly(3)), .rejected)
        XCTAssertEqual(matcher.verdict(on: Data([1, 2, 3, 4]), expecting: .exactly(3)), .rejected)
    }

    func testFillerBytesAreNotCounted() {
        let matcher = TailScanMatcher(fillerBytes: [0xFF])

        XCTAssertEqual(matcher.verdict(on: Data([0xFF, 0x43, 0xFF]), expecting: .exactly(1)), .accepted)
        XCTAssertEqual(matcher.verdict(on: Data([0xFF, 0xFF]), expecting: .exactly(1)), .rejected)
    }

    func testAnythingAcceptsEvenAnEmptyOrFillerOnlyCandidate() {
        let matcher = TailScanMatcher(fillerBytes: [0xFF])

        XCTAssertEqual(matcher.verdict(on: Data([0x41]), expecting: .anything), .accepted)
        XCTAssertEqual(matcher.verdict(on: Data([0xFF]), expecting: .anything), .accepted)
        XCTAssertEqual(matcher.verdict(on: Data(), expecting: .anything), .accepted)
    }

    func testNonASCIIIsUnreadableWhenASCIIIsRequired() {
        let matcher = TailScanMatcher(requiresASCII: true)

        XCTAssertEqual(matcher.verdict(on: Data([0x80]), expecting: .exactly(1)), .unreadable)
        XCTAssertEqual(matcher.verdict(on: Data([0x41, 0xC3]), expecting: .exactly(5)), .unreadable)
        XCTAssertEqual(matcher.verdict(on: Data([0x80]), expecting: .anything), .unreadable)
        XCTAssertEqual(matcher.verdict(on: Data([0x41]), expecting: .exactly(1)), .accepted)
    }

    func testNonASCIIIsFineWhenASCIIIsNotRequired() {
        let matcher = TailScanMatcher()

        XCTAssertEqual(matcher.verdict(on: Data([0x80]), expecting: .exactly(1)), .accepted)
    }

    func testAFillerByteAboveASCIIIsNotUnreadable() {
        XCTAssertEqual(padded.verdict(on: Data([0xFF, 0x43]), expecting: .exactly(1)), .accepted)
    }

    func testCharactersTreatCRLFAsOne() {
        let matcher = TailScanMatcher(lengthUnit: .characters)

        XCTAssertEqual(matcher.verdict(on: data("\r\n"), expecting: .exactly(1)), .accepted)
        XCTAssertEqual(matcher.verdict(on: data("\r\n"), expecting: .exactly(2)), .rejected)
        XCTAssertEqual(matcher.verdict(on: data("a\r\n"), expecting: .exactly(2)), .accepted)
    }

    func testBytesCountCRLFAsTwo() {
        let matcher = TailScanMatcher(lengthUnit: .bytes)

        XCTAssertEqual(matcher.verdict(on: data("\r\n"), expecting: .exactly(2)), .accepted)
        XCTAssertEqual(matcher.verdict(on: data("a\r\n"), expecting: .exactly(2)), .rejected)
    }

    func testCharactersDecodeLatin1ByteByByte() {
        // Each byte is one scalar, so two high bytes are two characters, never one UTF-8 sequence.
        let matcher = TailScanMatcher(lengthUnit: .characters)

        XCTAssertEqual(matcher.verdict(on: Data([0xC3, 0xA9]), expecting: .exactly(2)), .accepted)
    }

    // MARK: - scan

    func testAnEmptyBufferHasNoPacketAndNothingUnreadable() {
        XCTAssertEqual(padded.scan(Data(), expecting: .exactly(1)), ReplyScan(packet: nil, unreadable: nil))
        XCTAssertEqual(padded.scan(Data(), expecting: .anything), ReplyScan(packet: nil, unreadable: nil))
    }

    func testFillerBeforeTheReplyIsNotPartOfIt() {
        let scan = padded.scan(Data([0xFF, 0x43]), expecting: .exactly(1))

        XCTAssertEqual(scan.packet, Data([0x43]))
        XCTAssertNil(scan.unreadable)
    }

    func testFillerAfterTheReplyStaysInItRaw() {
        let scan = padded.scan(Data([0x43, 0xFF]), expecting: .exactly(1))

        XCTAssertEqual(scan.packet, Data([0x43, 0xFF]))
        XCTAssertNil(scan.unreadable)
    }

    func testFillerInsideTheReplyStaysInItRaw() {
        let scan = padded.scan(Data([0x41, 0xFF, 0x42]), expecting: .exactly(2))

        XCTAssertEqual(scan.packet, Data([0x41, 0xFF, 0x42]))
    }

    func testCharactersAcceptACRLFPairAsOne() {
        let scan = padded.scan(data("a\r\n"), expecting: .exactly(2))

        XCTAssertEqual(scan.packet, data("a\r\n"))
    }

    func testBytesAcceptTheLastTwoBytes() {
        let scan = TailScanMatcher(lengthUnit: .bytes).scan(data("a\r\n"), expecting: .exactly(2))

        XCTAssertEqual(scan.packet, data("\r\n"))
    }

    func testNonASCIIBytesLeaveNoPacketAndAreReported() {
        let scan = padded.scan(Data([0x80, 0x43]), expecting: .exactly(2))

        XCTAssertNil(scan.packet)
        XCTAssertEqual(scan.unreadable, Data([0x80, 0x43]))
    }

    func testTheLongestUnreadableCandidateIsReported() {
        let scan = padded.scan(Data([0x41, 0x80, 0x42, 0x43]), expecting: .exactly(9))

        XCTAssertNil(scan.packet)
        XCTAssertEqual(scan.unreadable, Data([0x41, 0x80, 0x42, 0x43]))
    }

    func testAnythingAcceptsTheVeryFirstByte() {
        let scan = padded.scan(Data([0x41]), expecting: .anything)

        XCTAssertEqual(scan.packet, Data([0x41]))
    }

    func testAnythingAcceptsALoneFillerByte() {
        let scan = padded.scan(Data([0xFF]), expecting: .anything)

        XCTAssertEqual(scan.packet, Data([0xFF]))
    }

    func testTheShortestTailWins() {
        let scan = TailScanMatcher().scan(data("XYZC"), expecting: .exactly(1))

        XCTAssertEqual(scan.packet, data("C"))
    }

    func testAnExactLengthRejectsShorterAndLongerBuffers() {
        let matcher = TailScanMatcher()

        XCTAssertNil(matcher.scan(Data([1, 2]), expecting: .exactly(3)).packet)
        XCTAssertEqual(matcher.scan(Data([1, 2, 3]), expecting: .exactly(3)).packet, Data([1, 2, 3]))
        XCTAssertEqual(matcher.scan(Data([1, 2, 3, 4]), expecting: .exactly(3)).packet, Data([2, 3, 4]))
    }

    func testTheBufferIsNotChangedAndThePacketStartsAtZero() {
        let parent = Data([0x58, 0x59, 0x5A, 0x43])
        let slice = parent[2...]
        XCTAssertEqual(slice.startIndex, 2)

        let scan = TailScanMatcher().scan(slice, expecting: .exactly(1))

        XCTAssertEqual(scan.packet, Data([0x43]))
        XCTAssertEqual(scan.packet?.startIndex, 0)
        XCTAssertEqual(slice, Data([0x5A, 0x43]))
    }

    func testAPacketFromASliceIsRebased() {
        let parent = Data([0x58, 0x59, 0x5A, 0x43])

        let scan = TailScanMatcher().scan(parent[1...], expecting: .exactly(2))

        XCTAssertEqual(scan.packet, Data([0x5A, 0x43]))
        XCTAssertEqual(scan.packet?.startIndex, 0)
    }

    // MARK: - The default scan with another matcher

    /// A matcher that only says what a candidate is, so the default `scan` does the rest.
    private struct RecordingMatcher: ReplyMatcher {
        let rule: (Data) -> ReplyVerdict
        let seen: SeenCandidates

        func verdict(on candidate: Data, expecting shape: ReplyShape) -> ReplyVerdict {
            seen.add(candidate)
            return rule(candidate)
        }
    }

    private final class SeenCandidates {
        private(set) var candidates: [Data] = []

        func add(_ candidate: Data) {
            candidates.append(candidate)
        }
    }

    func testTheDefaultScanTriesTailsFromShortestToLongestAndStopsAtTheFirstAccepted() {
        let seen = SeenCandidates()
        let matcher = RecordingMatcher(rule: { $0.count == 3 ? .accepted : .rejected }, seen: seen)

        let scan = matcher.scan(Data([1, 2, 3, 4, 5]), expecting: .anything)

        XCTAssertEqual(scan.packet, Data([3, 4, 5]))
        XCTAssertEqual(seen.candidates, [Data([5]), Data([4, 5]), Data([3, 4, 5])])
        XCTAssertTrue(seen.candidates.allSatisfy { $0.startIndex == 0 })
    }

    func testTheDefaultScanReportsTheLongestUnreadableTailBeforeTheAcceptedOne() {
        let matcher = RecordingMatcher(
            rule: { candidate in
                switch candidate.count {
                case 1, 2: return .unreadable
                case 3: return .accepted
                default: return .rejected
                }
            },
            seen: SeenCandidates()
        )

        let scan = matcher.scan(Data([1, 2, 3, 4]), expecting: .anything)

        XCTAssertEqual(scan.packet, Data([2, 3, 4]))
        XCTAssertEqual(scan.unreadable, Data([3, 4]))
    }

    func testTheDefaultScanTriesEveryTailWhenNothingIsAccepted() {
        let seen = SeenCandidates()
        let matcher = RecordingMatcher(rule: { _ in .rejected }, seen: seen)

        let scan = matcher.scan(Data([1, 2, 3]), expecting: .anything)

        XCTAssertEqual(scan, ReplyScan(packet: nil, unreadable: nil))
        XCTAssertEqual(seen.candidates.count, 3)
    }
}
