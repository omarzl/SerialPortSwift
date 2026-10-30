//
//  SimulatedChannelTests.swift
//  SerialPortSwiftConcurrencyTests
//
//  A `SimulatedByteStream` over a small test device, under a real `SerialChannel`: the simulator and the
//  channel tested together.
//

#if compiler(>=5.5) && canImport(_Concurrency)

    import SerialPortSwift
    import SerialPortSwiftConcurrency
    import SerialPortSwiftSimulation
    import XCTest

    /// A thermometer: it answers `T\r` with `21.5\n` and anything else with silence.
    private func thermometer() -> ScriptedDevice {
        return ScriptedDevice { frame in
            return frame == ascii("T\r") ? ascii("21.5\n") : nil
        }
    }

    @available(macOS 10.15, *)
    final class SimulatedChannelTests: XCTestCase {
        private func makeChannel(
            stream: SimulatedByteStream,
            matcher: ReplyMatcher = TailScanMatcher(),
            defaultTimeout: TimeInterval = 5,
            gap: TimeInterval = 0.1
        ) async -> (channel: SerialChannel, recorder: EventRecorder) {
            let channel = SerialChannel(
                stream: stream,
                matcher: matcher,
                configuration: SerialChannel.Configuration(defaultTimeout: defaultTimeout, postTimeoutGap: gap)
            )
            return (channel, await EventRecorder.attach(to: channel))
        }

        func testADeviceAnswersARequestAfterItsLatency() async throws {
            let stream = SimulatedByteStream(device: thermometer(), replyLatency: 0.05)
            let (channel, recorder) = await makeChannel(stream: stream)
            try await channel.open()

            let reply = try await channel.request(exchange(1, "T\r", reply: .exactly(5)))
            await waitUntil { recorder.has(.answered(1)) }

            XCTAssertEqual(reply, ascii("21.5\n"))
            guard let event = recorder.firstEvent(.answered(1)), case .answered(_, let roundTrip) = event.kind else {
                return XCTFail("No answer published")
            }
            XCTAssertGreaterThanOrEqual(roundTrip, 0.04)
            XCTAssertLessThan(roundTrip, 2)
            await recorder.expectTags([.opened, .sent(1), .raw, .answered(1)])
            await channel.close()
            recorder.stop()
        }

        func testFillerBytesInFrontOfEveryReplyAreSeenRawAndLeftOutOfTheReply() async throws {
            let stream = SimulatedByteStream(device: ScriptedDevice { _ in ascii("OK") }, replyLatency: 0.01)
            stream.fillerByteCount = 2
            let (channel, recorder) = await makeChannel(stream: stream, matcher: paddedMatcher)
            try await channel.open()

            let reply = try await channel.request(exchange(1, "q", reply: .exactly(2)))
            await waitUntil { recorder.has(.answered(1)) }

            XCTAssertEqual(reply, ascii("OK"))
            XCTAssertEqual(recorder.bytes(of: .raw), Data([0xFF, 0xFF, 0x4F, 0x4B]))
            await channel.close()
            recorder.stop()
        }

        func testADroppedReplyTimesOutAndTheNextRequestIsAnsweredAfterThePause() async throws {
            let gap: TimeInterval = 0.2
            let stream = SimulatedByteStream(device: thermometer(), replyLatency: 0.01)
            let (channel, recorder) = await makeChannel(stream: stream, gap: gap)
            try await channel.open()
            stream.dropNextReply()

            let first = Task { try await channel.request(exchange(1, "T\r", reply: .exactly(5), timeout: 0.2)) }
            await waitUntil { recorder.has(.sent(1)) }
            let second = Task { try await channel.request(exchange(2, "T\r", reply: .exactly(5))) }

            let firstError = await errorOf { try await first.value }
            let secondReply = try await second.value

            await waitUntil { recorder.has(.answered(2)) }

            XCTAssertEqual(firstError as? SerialChannelError, .timedOut)
            XCTAssertEqual(secondReply, ascii("21.5\n"))
            XCTAssertFalse(stream.isDropArmed)
            XCTAssertGreaterThanOrEqual(recorder.elapsed(from: .timedOut(1), to: .sent(2)), gap - 0.01)
            await channel.close()
            recorder.stop()
        }

        func testASilentDeviceMakesTheRequestTimeOut() async throws {
            let stream = SimulatedByteStream(device: thermometer(), replyLatency: 0.01)
            let (channel, recorder) = await makeChannel(stream: stream)
            try await channel.open()

            let error = await errorOf { try await channel.request(exchange(1, "?", reply: .anything, timeout: 0.2)) }

            XCTAssertEqual(error as? SerialChannelError, .timedOut)
            await channel.close()
            recorder.stop()
        }

        func testAnUnpluggedDeviceFailsTheRequestAndPluggingItBackInOpensTheChannelAgain() async throws {
            let stream = SimulatedByteStream(device: thermometer(), replyLatency: 0.2)
            let (channel, recorder) = await makeChannel(stream: stream)
            try await channel.open()
            let pending = Task { try await channel.request(exchange(1, "T\r", reply: .exactly(5))) }
            await waitUntil { recorder.has(.sent(1)) }

            stream.simulateRemoval()
            let error = await errorOf { try await pending.value }
            let notOpen = await errorOf { try await channel.request(exchange(2, "T\r", reply: .exactly(5))) }
            var isOpen = await channel.isOpen

            XCTAssertEqual(error as? SerialChannelError, .closed(.removed))
            XCTAssertEqual(notOpen as? SerialChannelError, .notOpen)
            XCTAssertFalse(isOpen)

            try await channel.open()
            let reply = try await channel.request(exchange(3, "T\r", reply: .exactly(5)))
            isOpen = await channel.isOpen

            XCTAssertEqual(reply, ascii("21.5\n"))
            XCTAssertTrue(isOpen)
            // The reply the unplugged device owed never turns up.
            await settle(0.4)
            await recorder.expectTagsWithoutRaw([.opened, .sent(1), .closed(.removed), .opened, .sent(3), .answered(3)])
            await channel.close()
            recorder.stop()
        }

        func testASlowDeviceIsWaitedForUpToTheTimeout() async throws {
            let stream = SimulatedByteStream(device: thermometer(), replyLatency: 0.3)
            let (channel, recorder) = await makeChannel(stream: stream)
            try await channel.open()

            let reply = try await channel.request(exchange(1, "T\r", reply: .exactly(5), timeout: 3))
            stream.replyLatency = 0
            let quick = try await channel.request(exchange(2, "T\r", reply: .exactly(5)))

            XCTAssertEqual(reply, ascii("21.5\n"))
            XCTAssertEqual(quick, ascii("21.5\n"))
            await channel.close()
            recorder.stop()
        }
    }

#endif
