//
//  SerialChannelTests.swift
//  SerialPortSwiftConcurrencyTests
//
//  The behaviour a `SerialChannel` shares with `SerialRequestQueue`, case by case, over a replay
//  stream: order, the wire, replies, timeouts, the pause after one, filler, the reply buffer.
//

#if compiler(>=5.7) && canImport(_Concurrency)

    import SerialPortSwift
    import SerialPortSwiftConcurrency
    import SerialPortSwiftSimulation
    import XCTest

    @available(macOS 10.15, *)
    final class SerialChannelTests: XCTestCase {
        func testTheConfigurationStartsWithTheQueuesDefaults() {
            let configuration = SerialChannel.Configuration()

            XCTAssertEqual(configuration.defaultTimeout, 1)
            XCTAssertEqual(configuration.maximumReplyLength, 64)
            XCTAssertEqual(configuration.postTimeoutGap, 0.1)
        }

        func testTheChannelKeepsTheConfigurationItWasMadeWithWhileTheGapItRunsWithMayChange() async throws {
            let configuration = SerialChannel.Configuration(defaultTimeout: 2, maximumReplyLength: 8, postTimeoutGap: 0.3)
            let channel = SerialChannel(stream: ReplayByteStream(), configuration: configuration)

            // No `await`: the configuration can be read from anywhere.
            XCTAssertEqual(channel.configuration.defaultTimeout, 2)
            XCTAssertEqual(channel.configuration.maximumReplyLength, 8)
            XCTAssertEqual(channel.configuration.postTimeoutGap, 0.3)

            await channel.setPostTimeoutGap(0.5)
            let gap = await channel.postTimeoutGap
            XCTAssertEqual(gap, 0.5)
            XCTAssertEqual(channel.configuration.postTimeoutGap, 0.3)
        }

        // MARK: Order and the wire

        func testItWritesInSubmissionOrderAndAWriteWaitsForTheExchangeAheadOfIt() async throws {
            try await withRig(script: [.silence(), .silence(), .silence()]) { rig in
                let first = Task { try await rig.channel.request(exchange(1, "1")) }
                await waitUntil { rig.stream.writes.count == 1 }
                let write = Task { try await rig.channel.send(ascii("w")) }
                await waitUntil { await queuedCount(of: rig.channel) == 1 }
                let second = Task { try await rig.channel.request(exchange(2, "2")) }
                await waitUntil { await queuedCount(of: rig.channel) == 2 }
                await settle(0.1)

                XCTAssertEqual(rig.writtenFrames, [ascii("1")])

                rig.stream.receive(ascii("A"))
                await waitUntil { rig.stream.writes.count == 3 }

                XCTAssertEqual(rig.writtenFrames, [ascii("1"), ascii("w"), ascii("2")])

                rig.stream.receive(ascii("B"))
                let firstReply = try await first.value
                try await write.value
                let secondReply = try await second.value

                XCTAssertEqual(firstReply, ascii("A"))
                XCTAssertEqual(secondReply, ascii("B"))
                XCTAssertEqual(rig.stream.writes.map { $0.matchedExpectation }, [true, true, true])
                await rig.recorder.expectTagsWithoutRaw(
                    [.opened, .sent(1), .answered(1), .sent(nil), .sent(2), .answered(2)]
                )
            }
        }

        func testWritesWithoutAReplyGoOutBackToBackInOrderAndEachReturnsOnceWritten() async throws {
            try await withRig(script: [.silence(), .silence(), .silence()]) { rig in
                try await rig.channel.send(ascii("a"))
                try await rig.channel.send(ascii("b"))
                try await rig.channel.send(ascii("c"))
                await waitUntil { rig.stream.writes.count == 3 }

                XCTAssertEqual(rig.writtenFrames, [ascii("a"), ascii("b"), ascii("c")])
                await rig.recorder.expectTagsWithoutRaw([.opened, .sent(nil), .sent(nil), .sent(nil)])
                XCTAssertEqual(rig.recorder.events.compactMap { $0.bytes }, [ascii("a"), ascii("b"), ascii("c")])
            }
        }

        func testOnlyOneExchangeIsOnTheWireAtATime() async throws {
            try await withRig(script: [.silence(), .silence()]) { rig in
                let first = Task { try await rig.channel.request(exchange(1, "1")) }
                await waitUntil { rig.stream.writes.count == 1 }
                let second = Task { try await rig.channel.request(exchange(2, "2")) }
                await waitUntil { await queuedCount(of: rig.channel) == 1 }
                await settle(0.1)

                XCTAssertEqual(rig.writtenFrames, [ascii("1")])
                XCTAssertFalse(rig.recorder.has(.sent(2)))

                rig.stream.receive(ascii("A"))
                await waitUntil { rig.recorder.has(.sent(2)) }
                await waitUntil { rig.stream.writes.count == 2 }
                rig.stream.receive(ascii("B"))
                _ = try await first.value
                _ = try await second.value

                XCTAssertEqual(rig.writtenFrames, [ascii("1"), ascii("2")])
                await rig.recorder.expectTagsWithoutRaw([.opened, .sent(1), .answered(1), .sent(2), .answered(2)])
            }
        }

        func testTheFrameIsPublishedAsSent() async throws {
            try await withRig(script: [.silence()]) { rig in
                let pending = Task { try await rig.channel.request(exchange(4, "frame")) }
                await waitUntil { rig.recorder.has(.sent(4)) }

                XCTAssertEqual(rig.recorder.bytes(of: .sent(4)), ascii("frame"))

                rig.stream.receive(ascii("A"))
                _ = try await pending.value
            }
        }

        func testARequestWithoutAnExchangePicksIncreasingIds() async throws {
            let script = Array(repeating: ReplayStep.reply(with: [ReplayChunk(ascii("A"), at: 0.01)]), count: 3)
            try await withRig(script: script) { rig in
                for _ in 0..<3 {
                    let reply = try await rig.channel.request(ascii("q"), reply: .exactly(1))
                    XCTAssertEqual(reply, ascii("A"))
                }

                await rig.recorder.expectTagsWithoutRaw(
                    [.opened, .sent(1), .answered(1), .sent(2), .answered(2), .sent(3), .answered(3)]
                )
            }
        }

        // MARK: Answers

        func testAnAnswerIsReturnedRawAndPublished() async throws {
            try await withRig(script: [.reply(with: [ReplayChunk(ascii("OK"), at: 0.1)])]) { rig in
                let reply = try await rig.channel.request(exchange(7, "q", reply: .exactly(2)))

                XCTAssertEqual(reply, ascii("OK"))
                await rig.recorder.expectTagsWithoutRaw([.opened, .sent(7), .answered(7)])
                XCTAssertEqual(rig.recorder.bytes(of: .answered(7)), ascii("OK"))
            }
        }

        func testTheRoundTripRunsFromTheWriteToTheReply() async throws {
            let offset: TimeInterval = 0.1
            try await withRig(script: [.reply(with: [ReplayChunk(ascii("OK"), at: offset)])]) { rig in
                _ = try await rig.channel.request(exchange(7, "q", reply: .exactly(2)))
                await waitUntil { rig.recorder.has(.answered(7)) }

                guard let event = rig.recorder.firstEvent(.answered(7)), case .answered(_, let roundTrip) = event.kind else {
                    return XCTFail("No answer published")
                }
                // The stream times the offset from its own write, a moment before the channel notes the write.
                XCTAssertGreaterThanOrEqual(roundTrip, offset - 0.05)
                XCTAssertLessThan(roundTrip, offset + 2)
                XCTAssertEqual(event.bytes, ascii("OK"))
            }
        }

        func testTheReplyOfAnAnythingExchangeIsTheFirstByte() async throws {
            try await withRig(script: [.reply(with: [ReplayChunk(ascii("xyz"), at: 0.02)])]) { rig in
                let reply = try await rig.channel.request(exchange(1, "q", reply: .anything))
                await waitUntil { rig.recorder.has(.unsolicited) }

                XCTAssertEqual(reply, ascii("x"))
                XCTAssertEqual(rig.recorder.bytes(of: .unsolicited), ascii("yz"))
            }
        }

        // MARK: Timeouts

        func testAnExchangeTimesOutAtItsOwnTimeoutWhenThatIsLongerThanTheDefault() async throws {
            try await withRig(script: [.silence()], defaultTimeout: 0.15) { rig in
                let error = await errorOf { try await rig.channel.request(exchange(1, "q", timeout: 0.4)) }
                await waitUntil { rig.recorder.has(.timedOut(1)) }

                XCTAssertEqual(error as? SerialChannelError, .timedOut)
                XCTAssertGreaterThanOrEqual(rig.recorder.elapsed(from: .sent(1), to: .timedOut(1)), 0.4 - 0.05)
                XCTAssertEqual(rig.recorder.bytes(of: .timedOut(1)), ascii("q"))
            }
        }

        func testAnExchangeWithoutATimeoutUsesTheDefault() async throws {
            try await withRig(script: [.silence()], defaultTimeout: 0.2) { rig in
                let error = await errorOf { try await rig.channel.request(exchange(1, "q")) }
                await waitUntil { rig.recorder.has(.timedOut(1)) }

                XCTAssertEqual(error as? SerialChannelError, .timedOut)
                XCTAssertGreaterThanOrEqual(rig.recorder.elapsed(from: .sent(1), to: .timedOut(1)), 0.2 - 0.05)
            }
        }

        func testAShorterOwnTimeoutBeatsALaterReply() async throws {
            try await withRig(script: [.reply(with: [ReplayChunk(ascii("A"), at: 0.3)])], defaultTimeout: 5) { rig in
                let error = await errorOf { try await rig.channel.request(exchange(1, "q", timeout: 0.05)) }
                // The reply, due 0.3 s after the write, finds nothing on the wire.
                await waitUntil { rig.recorder.has(.unsolicited) }

                XCTAssertEqual(error as? SerialChannelError, .timedOut)
                await rig.recorder.expectTagsWithoutRaw([.opened, .sent(1), .timedOut(1), .unsolicited])
            }
        }

        func testTheNextExchangeIsWrittenAfterATimeout() async throws {
            let script: [ReplayStep] = [.silence(), .reply(with: [ReplayChunk(ascii("B"), at: 0.02)])]
            try await withRig(script: script, gap: 0) { rig in
                let first = Task { try await rig.channel.request(exchange(1, "1", timeout: 0.1)) }
                await waitUntil { rig.stream.writes.count == 1 }
                let second = Task { try await rig.channel.request(exchange(2, "2")) }
                await waitUntil { await queuedCount(of: rig.channel) == 1 }

                let firstError = await errorOf { try await first.value }
                let secondReply = try await second.value

                XCTAssertEqual(firstError as? SerialChannelError, .timedOut)
                XCTAssertEqual(secondReply, ascii("B"))
            }
        }

        func testATimerThatBelongsToAnEarlierExchangeDoesNotTimeOutTheOneOnTheWire() async throws {
            let script: [ReplayStep] = [.reply(with: [ReplayChunk(ascii("A"), at: 0.01)]), .silence()]
            try await withRig(script: script) { rig in
                _ = try await rig.channel.request(exchange(1, "1"))
                let second = Task { try await rig.channel.request(exchange(2, "2")) }
                await waitUntil { rig.recorder.has(.sent(2)) }

                // The timer of the first exchange, late (token 1), and two that belong to nothing.
                await fireTimeout(1, of: rig.channel)
                await fireTimeout(0, of: rig.channel)
                await fireTimeout(3, of: rig.channel)
                await settle(0.1)

                XCTAssertFalse(rig.recorder.has(.timedOut(2)))
                rig.stream.receive(ascii("B"))
                let reply = try await second.value
                XCTAssertEqual(reply, ascii("B"))
                await rig.recorder.expectTagsWithoutRaw([.opened, .sent(1), .answered(1), .sent(2), .answered(2)])
            }
        }

        // MARK: The pause after a timeout

        func testARequestMadeInsideThePauseIsNotWrittenUntilThePauseEnds() async throws {
            let gap: TimeInterval = 0.5
            let script: [ReplayStep] = [.silence(), .reply(with: [ReplayChunk(ascii("B"), at: 0.01)])]
            try await withRig(script: script, gap: gap) { rig in
                let first = Task { try await rig.channel.request(exchange(1, "1", timeout: 0.05)) }
                _ = await errorOf { try await first.value }
                await waitUntil { rig.recorder.has(.timedOut(1)) }

                let second = Task { try await rig.channel.request(exchange(2, "2")) }
                await settle(0.2)

                XCTAssertEqual(rig.stream.writes.count, 1, "the second frame was written inside the pause")
                let reply = try await second.value
                XCTAssertEqual(reply, ascii("B"))
                XCTAssertGreaterThanOrEqual(rig.recorder.elapsed(from: .timedOut(1), to: .sent(2)), gap - 0.05)
            }
        }

        func testAPauseTokenThatIsStaleDoesNotEndThePause() async throws {
            try await withRig(script: [.silence(), .silence(), .silence()], gap: 0.05) { rig in
                // The first timeout starts a short pause (token 1), the second a long one (token 2).
                let first = Task { try await rig.channel.request(exchange(1, "1", timeout: 0.05)) }
                _ = await errorOf { try await first.value }
                await rig.channel.setPostTimeoutGap(30)
                let second = Task { try await rig.channel.request(exchange(2, "2", timeout: 0.05)) }
                _ = await errorOf { try await second.value }
                let third = Task { try await rig.channel.request(exchange(3, "3")) }
                await waitUntil { await queuedCount(of: rig.channel) == 1 }

                // The end of the first pause, late, and two that belong to nothing.
                await endPause(1, of: rig.channel)
                await endPause(0, of: rig.channel)
                await endPause(3, of: rig.channel)
                await settle(0.1)

                XCTAssertFalse(rig.recorder.has(.sent(3)), "a stale token ended the pause")
                XCTAssertEqual(rig.stream.writes.count, 2)

                await endPause(2, of: rig.channel)
                await waitUntil { rig.recorder.has(.sent(3)) }
                rig.stream.receive(ascii("C"))
                let reply = try await third.value
                XCTAssertEqual(reply, ascii("C"))
            }
        }

        func testBytesThatArrivedBeforeThePauseEndedAreLateEvenIfTheChannelHearsOfThemAfterwards() async throws {
            // The channel is kept busy, in the scan of a chunk, while the stream posts "L" and the pause after a
            // timeout ends. When the channel is free again the pause is over and "2" is written, and only then
            // does it hear of "L". "L" came during the pause: it is late, and it does not answer "2".
            let scanning = Flag()
            let release = DispatchSemaphore(value: 0)
            let rig = await ManualRig(
                matcher: HookedMatcher {
                    // Only the first scan waits: a second one means the channel took "L" for a reply.
                    if !scanning.isRaised {
                        scanning.raise()
                        release.wait()
                    }
                },
                gap: 30
            )
            try await rig.open()
            let stream = rig.stream
            let first = Task { try await rig.channel.request(exchange(1, "1", reply: .exactly(2), timeout: 5)) }
            await waitUntil { stream.writes.count == 1 }
            let second = Task { try await rig.channel.request(exchange(2, "2", timeout: 0.3)) }
            await waitUntil { await queuedCount(of: rig.channel) == 1 }

            // "a" is half of the reply to "1". The channel scans it, and stays in the scan.
            stream.deliver(ascii("a"))
            await waitUntil { scanning.isRaised }
            // Behind it, in this order: the timeout of "1", the end of the pause it starts, and (once the
            // channel is free) the chunk "L" posted meanwhile.
            Task(priority: .userInitiated) { await fireTimeout(1, of: rig.channel) }
            await settle(0.1)
            Task(priority: .userInitiated) { await endPause(1, of: rig.channel) }
            await settle(0.1)
            stream.deliver(ascii("L"))
            release.signal()

            let firstError = await errorOf { try await first.value }
            let secondError = await errorOf { try await second.value }

            XCTAssertEqual(firstError as? SerialChannelError, .timedOut)
            XCTAssertEqual(secondError as? SerialChannelError, .timedOut)
            await rig.recorder.expectTagsWithoutRaw([.opened, .sent(1), .timedOut(1), .sent(2), .late, .timedOut(2)])
            XCTAssertEqual(rig.recorder.bytes(of: .late), ascii("L"))
            await rig.shutDown()
        }

        func testALateReplyInsideTheGapIsNotCreditedToTheNextExchange() async throws {
            let gap: TimeInterval = 0.4
            let script: [ReplayStep] = [.silence(), .reply(with: [ReplayChunk(ascii("B"), at: 0.05)])]
            let stream = ReplayByteStream(script: script)
            let channel = SerialChannel(
                stream: stream,
                configuration: SerialChannel.Configuration(defaultTimeout: 5, postTimeoutGap: gap)
            )
            // The late byte arrives well inside the pause that follows the timeout.
            let recorder = await EventRecorder.attach(to: channel) { @Sendable event in
                if event.kind == .timedOut(SerialExchangeID(number: 1)) {
                    stream.receive(ascii("L"), after: 0.05)
                }
            }
            try await channel.open()

            let first = Task { try await channel.request(exchange(1, "1", timeout: 0.15)) }
            await waitUntil { stream.writes.count == 1 }
            let second = Task { try await channel.request(exchange(2, "2")) }
            await waitUntil { await queuedCount(of: channel) == 1 }

            let firstError = await errorOf { try await first.value }
            let secondReply = try await second.value

            XCTAssertEqual(firstError as? SerialChannelError, .timedOut)
            XCTAssertEqual(secondReply, ascii("B"))
            await recorder.expectTagsWithoutRaw([.opened, .sent(1), .timedOut(1), .late, .sent(2), .answered(2)])
            XCTAssertEqual(recorder.bytes(of: .late), ascii("L"))
            XCTAssertGreaterThanOrEqual(recorder.elapsed(from: .timedOut(1), to: .sent(2)), gap - 0.05)
            await channel.close()
            recorder.stop()
        }

        func testAZeroGapWritesTheNextExchangeRightAfterATimeout() async throws {
            try await withRig(script: [.silence(), .silence()], gap: 2) { rig in
                let startingGap = await rig.channel.postTimeoutGap
                XCTAssertEqual(startingGap, 2)
                await rig.channel.setPostTimeoutGap(0)
                let changedGap = await rig.channel.postTimeoutGap
                XCTAssertEqual(changedGap, 0)

                let first = Task { try await rig.channel.request(exchange(1, "1", timeout: 0.1)) }
                await waitUntil { rig.stream.writes.count == 1 }
                let second = Task { try await rig.channel.request(exchange(2, "2", timeout: 5)) }
                await waitUntil { rig.recorder.has(.sent(2)) }

                XCTAssertLessThan(rig.recorder.elapsed(from: .timedOut(1), to: .sent(2)), 1)
                let firstError = await errorOf { try await first.value }
                XCTAssertEqual(firstError as? SerialChannelError, .timedOut)
                rig.stream.receive(ascii("B"))
                _ = try await second.value
            }
        }

        func testChangingTheGapAppliesFromTheNextTimeout() async throws {
            let gap: TimeInterval = 0.4
            let stream = ReplayByteStream(script: [.silence(), .silence(), .silence()])
            let channel = SerialChannel(
                stream: stream,
                configuration: SerialChannel.Configuration(defaultTimeout: 5, postTimeoutGap: 0)
            )
            // The first timeout is over by the time the event is heard; the change is for the next.
            let recorder = await EventRecorder.attach(to: channel) { @Sendable event in
                if event.kind == .timedOut(SerialExchangeID(number: 1)) {
                    Task { await channel.setPostTimeoutGap(gap) }
                }
            }
            try await channel.open()

            let first = Task { try await channel.request(exchange(1, "1", timeout: 0.5)) }
            await waitUntil { stream.writes.count == 1 }
            let second = Task { try await channel.request(exchange(2, "2", timeout: 0.4)) }
            await waitUntil { await queuedCount(of: channel) == 1 }
            let third = Task { try await channel.request(exchange(3, "3", timeout: 5)) }
            await waitUntil { await queuedCount(of: channel) == 2 }
            await waitUntil { recorder.has(.sent(3)) }

            let changedGap = await channel.postTimeoutGap
            XCTAssertEqual(changedGap, gap)
            XCTAssertGreaterThanOrEqual(recorder.elapsed(from: .timedOut(2), to: .sent(3)), gap - 0.05)
            _ = await first.result
            _ = await second.result
            stream.receive(ascii("C"))
            _ = try await third.value
            await channel.close()
            recorder.stop()
        }

        // MARK: Filler and what the events show

        func testAnInjectedFillerByteIsVisibleRawWithItsTimestampAndLeftOutOfTheReply() async throws {
            try await withRig(script: [.silence()], matcher: paddedMatcher) { rig in
                let pending = Task { try await rig.channel.request(exchange(1, "q")) }
                await waitUntil { rig.recorder.has(.sent(1)) }

                let before = Date()
                rig.stream.receive(Data([0xFF, 0x43]))
                let reply = try await pending.value
                let after = Date()
                await waitUntil { rig.recorder.has(.answered(1)) }

                guard let raw = rig.recorder.firstEvent(.raw) else {
                    return XCTFail("No raw event")
                }
                XCTAssertEqual(raw.bytes, Data([0xFF, 0x43]))
                XCTAssertGreaterThanOrEqual(raw.date, before)
                XCTAssertLessThanOrEqual(raw.date, after)
                XCTAssertEqual(reply, Data([0x43]))
                XCTAssertEqual(rig.recorder.bytes(of: .answered(1)), Data([0x43]))
            }
        }

        func testTheRawEventComesBeforeAnythingDecidedAboutTheBytes() async throws {
            try await withRig(script: [.silence()], matcher: paddedMatcher) { rig in
                let pending = Task { try await rig.channel.request(exchange(1, "q")) }
                await waitUntil { rig.recorder.has(.sent(1)) }

                rig.stream.receive(Data([0xFF, 0x43]))
                _ = try await pending.value

                await rig.recorder.expectTags([.opened, .sent(1), .raw, .answered(1)])
            }
        }

        func testFillerAfterTheReplyInTheSameChunkIsDroppedWithTheRestOfIt() async throws {
            // The reply is complete at its last byte, so what follows in the chunk is not part of it.
            try await withRig(script: [.silence()], matcher: paddedMatcher) { rig in
                let pending = Task { try await rig.channel.request(exchange(1, "q")) }
                await waitUntil { rig.recorder.has(.sent(1)) }

                rig.stream.receive(Data([0x43, 0xFF]))
                let reply = try await pending.value
                await waitUntil { rig.recorder.has(.unsolicited) }

                XCTAssertEqual(reply, Data([0x43]))
                XCTAssertEqual(rig.recorder.bytes(of: .unsolicited), Data([0xFF]))
            }
        }

        func testFillerInsideTheReplyStaysInItRaw() async throws {
            try await withRig(script: [.silence()], matcher: paddedMatcher) { rig in
                let pending = Task { try await rig.channel.request(exchange(1, "q", reply: .exactly(2))) }
                await waitUntil { rig.recorder.has(.sent(1)) }

                rig.stream.receive(Data([0x41, 0xFF, 0x42]))
                let reply = try await pending.value

                XCTAssertEqual(reply, Data([0x41, 0xFF, 0x42]))
            }
        }

        func testCharactersFindAReplyAtItsCarriageReturnAndTheLineFeedArrivesWithNothingInFlight() async throws {
            let script: [ReplayStep] = [
                .reply(with: [ReplayChunk(ascii("OK\r"), at: 0.02), ReplayChunk(ascii("\n"), at: 0.1)])
            ]
            try await withRig(script: script, matcher: TailScanMatcher(lengthUnit: .characters)) { rig in
                let reply = try await rig.channel.request(exchange(1, "q", reply: .exactly(3)))
                await waitUntil { rig.recorder.has(.unsolicited) }

                XCTAssertEqual(reply, ascii("OK\r"))
                XCTAssertEqual(rig.recorder.bytes(of: .unsolicited), ascii("\n"))
                await rig.recorder.expectTagsWithoutRaw([.opened, .sent(1), .answered(1), .unsolicited])
            }
        }

        func testBytesTakeTheWholeCarriageReturnLineFeedEnding() async throws {
            let script: [ReplayStep] = [
                .reply(with: [ReplayChunk(ascii("OK\r"), at: 0.02), ReplayChunk(ascii("\n"), at: 0.1)])
            ]
            try await withRig(script: script, matcher: TailScanMatcher(lengthUnit: .bytes)) { rig in
                let reply = try await rig.channel.request(exchange(1, "q", reply: .exactly(4)))
                await settle(0.2)

                XCTAssertEqual(reply, ascii("OK\r\n"))
                XCTAssertFalse(rig.recorder.has(.unsolicited))
            }
        }

        func testANonASCIIByteIsPublishedAsAnUnreadableCandidate() async throws {
            try await withRig(script: [.silence()], matcher: paddedMatcher) { rig in
                let pending = Task { try await rig.channel.request(exchange(1, "q", reply: .exactly(2), timeout: 0.3)) }
                await waitUntil { rig.recorder.has(.sent(1)) }

                rig.stream.receive(Data([0x80, 0x43]))
                let error = await errorOf { try await pending.value }

                XCTAssertEqual(error as? SerialChannelError, .timedOut)
                await rig.recorder.expectTagsWithoutRaw([.opened, .sent(1), .unreadable(1), .unreadable(1), .timedOut(1)])
                let unreadable = rig.recorder.events.filter { Tag($0.kind) == .unreadable(1) }.map { $0.bytes }
                XCTAssertEqual(unreadable, [Data([0x80]), Data([0x80, 0x43])])
            }
        }

        // MARK: The reply buffer

        func testTheReplyBufferIsBoundedAndKeepsTheLatestBytes() async throws {
            let log = ScanLog()
            try await withRig(script: [.silence()], matcher: LoggingMatcher(log: log), maximumReplyLength: 4) { rig in
                _ = Task { try await rig.channel.request(exchange(1, "q", reply: .exactly(3))) }
                await waitUntil { rig.recorder.has(.sent(1)) }

                rig.stream.receive(Data([1, 2, 3, 4, 5, 6]))
                rig.stream.receive(Data([7, 8]))
                await waitUntil { log.buffers.count == 8 }

                XCTAssertEqual(log.buffers, [
                    Data([1]), Data([1, 2]), Data([1, 2, 3]), Data([1, 2, 3, 4]),
                    Data([2, 3, 4, 5]), Data([3, 4, 5, 6]), Data([4, 5, 6, 7]), Data([5, 6, 7, 8])
                ])
                XCTAssertTrue(log.buffers.allSatisfy { $0.count <= 4 })
                XCTAssertTrue(log.startIndexes.allSatisfy { $0 == 0 })
            }
        }

        func testAnExactLengthLongerThanTheLimitKeepsEnoughBytesToBeFound() async throws {
            let log = ScanLog()
            try await withRig(script: [.silence()], matcher: LoggingMatcher(log: log), maximumReplyLength: 4) { rig in
                _ = Task { try await rig.channel.request(exchange(1, "q", reply: .exactly(6))) }
                await waitUntil { rig.recorder.has(.sent(1)) }

                rig.stream.receive(Data([1, 2, 3, 4, 5, 6, 7, 8]))
                await waitUntil { log.buffers.count == 8 }

                XCTAssertEqual(log.buffers, [
                    Data([1]), Data([1, 2]), Data([1, 2, 3]), Data([1, 2, 3, 4]), Data([1, 2, 3, 4, 5]),
                    Data([1, 2, 3, 4, 5, 6]), Data([2, 3, 4, 5, 6, 7]), Data([3, 4, 5, 6, 7, 8])
                ])
            }
        }

        func testAnExchangeThatExpectsMoreThanTheDefaultLimitIsAnswered() async throws {
            let reply = Data((0..<100).map { UInt8($0) })
            let script: [ReplayStep] = [
                .reply(with: [ReplayChunk(reply.prefix(60), at: 0.02), ReplayChunk(reply.suffix(40), at: 0.04)])
            ]
            try await withRig(script: script) { rig in
                let answer = try await rig.channel.request(exchange(1, "q", reply: .exactly(100)))

                XCTAssertEqual(answer, reply)
                await rig.recorder.expectTagsWithoutRaw([.opened, .sent(1), .answered(1)])
            }
        }

        func testTheLimitStillAppliesToExchangesThatNeedLess() async throws {
            let log = ScanLog()
            try await withRig(script: [.silence()], matcher: LoggingMatcher(log: log), maximumReplyLength: 4) { rig in
                _ = Task { try await rig.channel.request(exchange(1, "q", reply: .anything)) }
                await waitUntil { rig.recorder.has(.sent(1)) }

                rig.stream.receive(Data([1, 2, 3, 4, 5, 6]))
                await waitUntil { log.buffers.count == 6 }

                XCTAssertTrue(log.buffers.allSatisfy { $0.count <= 4 })
            }
        }

        func testTheBufferStartsEmptyForEachExchange() async throws {
            let log = ScanLog()
            try await withRig(script: [.silence(), .silence()], matcher: LoggingMatcher(log: log)) { rig in
                _ = Task { try await rig.channel.request(exchange(1, "1", timeout: 0.4)) }
                await waitUntil { rig.recorder.has(.sent(1)) }
                _ = Task { try await rig.channel.request(exchange(2, "2", timeout: 5)) }
                await waitUntil { await queuedCount(of: rig.channel) == 1 }
                rig.stream.receive(Data([1, 2]))
                await waitUntil { rig.recorder.has(.sent(2)) }
                rig.stream.receive(Data([3]))
                await waitUntil { log.buffers.count == 3 }

                XCTAssertEqual(log.buffers, [Data([1]), Data([1, 2]), Data([3])])
            }
        }

        func testBytesLeftInAChunkAfterTheReplyAreDroppedNotGivenToTheNextExchange() async throws {
            let script: [ReplayStep] = [
                .reply(with: [ReplayChunk(ascii("CXY"), at: 0.05)]),
                .reply(with: [ReplayChunk(ascii("Q"), at: 0.2)])
            ]
            try await withRig(script: script) { rig in
                let first = Task { try await rig.channel.request(exchange(1, "1")) }
                await waitUntil { rig.stream.writes.count == 1 }
                let second = Task { try await rig.channel.request(exchange(2, "2")) }

                let firstReply = try await first.value
                let secondReply = try await second.value

                XCTAssertEqual(firstReply, ascii("C"))
                XCTAssertEqual(secondReply, ascii("Q"))
                await rig.recorder.expectTagsWithoutRaw([.opened, .sent(1), .answered(1), .unsolicited, .sent(2), .answered(2)])
                XCTAssertEqual(rig.recorder.bytes(of: .unsolicited), ascii("XY"))
            }
        }

        func testBytesWithNothingInFlightAreDroppedAsUnsolicited() async throws {
            try await withRig { rig in
                rig.stream.receive(ascii("zz"))
                await waitUntil { rig.recorder.has(.unsolicited) }

                await rig.recorder.expectTags([.opened, .raw, .unsolicited])
                XCTAssertEqual(rig.recorder.bytes(of: .raw), ascii("zz"))
                XCTAssertEqual(rig.recorder.bytes(of: .unsolicited), ascii("zz"))
            }
        }

        func testBytesBeforeAnExchangeIsWrittenAreNotItsReply() async throws {
            try await withRig(script: [.silence()]) { rig in
                rig.stream.receive(ascii("early"))
                await waitUntil { rig.recorder.has(.unsolicited) }

                let error = await errorOf { try await rig.channel.request(exchange(1, "q", timeout: 0.15)) }

                XCTAssertEqual(error as? SerialChannelError, .timedOut)
            }
        }

        func testBytesThatArrivedBeforeTheFrameWentOutAreNotItsReplyEvenIfTheChannelHearsOfThemAfterwards() async throws {
            // The stream and the channel are two places: a byte can be received before a frame is written and
            // be heard of by the channel after. Here the channel is kept busy on purpose: the stream reports
            // "X" from inside the write of "w", and "2" is written in the same turn. "X" came first, so it does
            // not answer "2".
            let rig = await ManualRig()
            try await rig.open()
            let stream = rig.stream
            stream.onWrite = { @Sendable frame in
                if frame == ascii("w") {
                    stream.deliver(ascii("X"))
                }
            }
            let first = Task { try await rig.channel.request(exchange(1, "1")) }
            await waitUntil { stream.writes.count == 1 }
            let write = Task { try await rig.channel.send(ascii("w")) }
            await waitUntil { await queuedCount(of: rig.channel) == 1 }
            let second = Task { try await rig.channel.request(exchange(2, "2", timeout: 0.3)) }
            await waitUntil { await queuedCount(of: rig.channel) == 2 }

            stream.deliver(ascii("A"))
            let firstReply = try await first.value
            try await write.value
            let error = await errorOf { try await second.value }

            XCTAssertEqual(firstReply, ascii("A"))
            XCTAssertEqual(error as? SerialChannelError, .timedOut)
            await rig.recorder.expectTagsWithoutRaw(
                [.opened, .sent(1), .answered(1), .sent(nil), .sent(2), .unsolicited, .timedOut(2)]
            )
            XCTAssertEqual(rig.recorder.bytes(of: .unsolicited), ascii("X"))
            await rig.shutDown()
        }

        func testBytesDeliveredJustBeforeACallAreNeverItsReply() async throws {
            // The same without help, whichever of the byte and the call the channel hears of first.
            let stream = ManualByteStream()
            let configuration = SerialChannel.Configuration(defaultTimeout: 0.02, maximumReplyLength: 64, postTimeoutGap: 0)
            let channel = SerialChannel(stream: stream, configuration: configuration)
            let opening = Task { try await channel.open() }
            await waitUntil { stream.openCalls == 1 }
            stream.completeOpen()
            try await opening.value

            var credited = 0
            for _ in 0..<50 {
                stream.deliver(ascii("X"))
                let error = await errorOf { try await channel.request(ascii("q"), reply: .exactly(1)) }
                if error == nil {
                    credited += 1
                }
            }

            XCTAssertEqual(credited, 0, "\(credited) of 50 requests were answered by a byte that arrived before they were made")
            await channel.close()
        }

        // MARK: Priorities

        func testThePumpAndTheTimersRunAtTheirOwnPriorityAndNotAtThatOfTheTaskThatStartedThem() async throws {
            let scanned = Box<TaskPriority?>(nil)
            let written = Box<TaskPriority?>(nil)
            let rig = await ManualRig(matcher: HookedMatcher { scanned.value = Task.currentPriority }, gap: 0.05)
            let stream = rig.stream
            let channel = rig.channel
            // The frame "2" is written when the pause after the timeout of "1" ends, in the task of that pause.
            stream.onWrite = { @Sendable frame in
                if frame == ascii("2") {
                    written.value = Task.currentPriority
                }
            }
            let finished = Flag()

            // The first calls, the ones that start the pump and the timers, are made from a background task. The
            // test does not await it, so that waiting does not raise its priority.
            Task(priority: .background) {
                try await rig.open()
                let first = Task { try await channel.request(exchange(1, "1", timeout: 0.05)) }
                _ = await errorOf { try await first.value }
                let second = Task { try await channel.request(exchange(2, "2")) }
                await waitUntil { stream.writes.count == 2 }
                stream.deliver(ascii("B"))
                _ = try await second.value
                finished.raise()
            }
            await waitUntil { finished.isRaised }

            // At least: a priority can be raised, by a waiter of a higher one, but never lower than its own.
            XCTAssertGreaterThanOrEqual(scanned.value ?? .background, .userInitiated, "the pump runs at the priority of its first caller")
            XCTAssertGreaterThanOrEqual(written.value ?? .background, .userInitiated, "the timers run at the priority of the request that started them")
            await rig.shutDown()
        }

        // MARK: A channel names itself

        func testItNamesItselfAfterTheStreamAndTheChannelIsItsDelegate() {
            let stream = ReplayByteStream(name: "replayed")
            let channel = SerialChannel(stream: stream)

            XCTAssertEqual(channel.name, "replayed")
            XCTAssertNotNil(stream.delegate)
            XCTAssertNil((channel as AnyObject) as? SerialByteStreamDelegate)
        }
    }

#endif
