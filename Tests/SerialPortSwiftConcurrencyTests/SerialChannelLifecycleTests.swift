//
//  SerialChannelLifecycleTests.swift
//  SerialPortSwiftConcurrencyTests
//
//  Opening, closing and everything that ends a session: a close asked for, a stream that goes away or
//  fails, an open that fails, a stream that opens late, a channel used when it is not open.
//

#if compiler(>=5.7) && canImport(_Concurrency)

    import SerialPortSwift
    import SerialPortSwiftConcurrency
    import SerialPortSwiftSimulation
    import XCTest

    /// A device that never answers.
    private let silentDevice = ScriptedDevice { _ in nil }

    @available(macOS 10.15, *)
    final class SerialChannelLifecycleTests: XCTestCase {
        // MARK: Closing

        func testCloseFailsTheQueuedAndTheOnTheWireRequestsAndNothingArrivesAfterIt() async throws {
            try await withRig(script: [.reply(with: [ReplayChunk(ascii("A"), at: 0.1)])]) { rig in
                let first = Task { try await rig.channel.request(exchange(1, "1", timeout: 0.2)) }
                await waitUntil { rig.stream.writes.count == 1 }
                let second = Task { try await rig.channel.request(exchange(2, "2")) }
                await waitUntil { await queuedCount(of: rig.channel) == 1 }

                await rig.channel.close()

                let firstError = await errorOf { try await first.value }
                let secondError = await errorOf { try await second.value }
                XCTAssertEqual(firstError as? SerialChannelError, .closed(.requested))
                XCTAssertEqual(secondError as? SerialChannelError, .closed(.requested))
                let isOpen = await rig.channel.isOpen
                XCTAssertFalse(isOpen)

                // Neither the first request's timer (0.2 s) nor its reply (0.1 s) reaches anyone.
                await settle(0.5)
                await rig.recorder.expectTags([.opened, .sent(1), .closed(.requested)])
                XCTAssertEqual(rig.writtenFrames, [ascii("1")])
            }
        }

        func testWhatTheStreamDeliversAfterACloseIsIgnored() async throws {
            let rig = await ManualRig()
            try await rig.open()
            let pending = Task { try await rig.channel.request(exchange(1, "1", timeout: 0.2)) }
            await waitUntil { rig.recorder.has(.sent(1)) }

            await rig.channel.close()
            rig.stream.deliver(ascii("A"))
            let error = await errorOf { try await pending.value }
            await settle(0.4)

            XCTAssertEqual(error as? SerialChannelError, .closed(.requested))
            await rig.recorder.expectTags([.opened, .sent(1), .closed(.requested)])
            rig.recorder.stop()
        }

        func testClosingTwiceReportsOnce() async throws {
            try await withRig { rig in
                await rig.channel.close()
                await rig.channel.close()

                await rig.recorder.expectTags([.opened, .closed(.requested)])
            }
        }

        func testClosingAChannelThatWasNeverOpenedDoesNothing() async throws {
            try await withRig(open: false) { rig in
                await rig.channel.close()

                await rig.recorder.expectTags([])
            }
        }

        func testAStreamThatEndsAsRemovedClosesTheChannelAndFailsTheRequestOnTheWire() async throws {
            try await withRig(script: [.silence()]) { rig in
                let pending = Task { try await rig.channel.request(exchange(1, "1", timeout: 5)) }
                await waitUntil { rig.recorder.has(.sent(1)) }

                rig.stream.end(.removed, after: 0.02)
                let error = await errorOf { try await pending.value }
                await settle(0.2)
                await rig.channel.close()

                XCTAssertEqual(error as? SerialChannelError, .closed(.removed))
                let isOpen = await rig.channel.isOpen
                XCTAssertFalse(isOpen)
                await rig.recorder.expectTags([.opened, .sent(1), .closed(.removed)])
            }
        }

        func testAStreamThatEndsFailsTheQueuedRequestsToo() async throws {
            try await withRig(script: [.silence()]) { rig in
                let first = Task { try await rig.channel.request(exchange(1, "1", timeout: 5)) }
                await waitUntil { rig.recorder.has(.sent(1)) }
                let second = Task { try await rig.channel.request(exchange(2, "2")) }
                await waitUntil { await queuedCount(of: rig.channel) == 1 }

                rig.stream.end(.removed, after: 0)

                let firstError = await errorOf { try await first.value }
                let secondError = await errorOf { try await second.value }
                XCTAssertEqual(firstError as? SerialChannelError, .closed(.removed))
                XCTAssertEqual(secondError as? SerialChannelError, .closed(.removed))
                XCTAssertEqual(rig.writtenFrames, [ascii("1")])
            }
        }

        func testAStreamThatFailsWhileOpenClosesTheChannelWithTheFailure() async throws {
            let failure = SerialStreamError.readFailed(code: 5)
            try await withRig { rig in
                rig.stream.end(.failed(failure), after: 0)
                await waitUntil { rig.recorder.has(.closed(.failed(failure))) }

                let isOpen = await rig.channel.isOpen
                XCTAssertFalse(isOpen)
                await rig.recorder.expectTags([.opened, .closed(.failed(failure))])
            }
        }

        func testAChannelThatTheDeviceRemovedOpensAgain() async throws {
            let script: [ReplayStep] = [.reply(with: [ReplayChunk(ascii("N"), at: 0.02)])]
            try await withRig(script: script) { rig in
                rig.stream.end(.removed, after: 0)
                await waitUntil { rig.recorder.has(.closed(.removed)) }

                try await rig.channel.open()
                let reply = try await rig.channel.request(exchange(1, "1"))

                XCTAssertEqual(reply, ascii("N"))
                await rig.recorder.expectTagsWithoutRaw([.opened, .closed(.removed), .opened, .sent(1), .answered(1)])
            }
        }

        // MARK: Opening

        func testOpenReturnsOnceTheStreamHasReportedAndOpeningAnOpenChannelDoesNothing() async throws {
            try await withRig(open: false) { rig in
                var isOpen = await rig.channel.isOpen
                XCTAssertFalse(isOpen)

                try await rig.channel.open()
                isOpen = await rig.channel.isOpen
                XCTAssertTrue(isOpen)
                XCTAssertEqual(rig.stream.isOpen, true)

                try await rig.channel.open()
                await settle(0.05)

                await rig.recorder.expectTags([.opened])
            }
        }

        func testAnOpenFailureThrowsTheFailureAndTheChannelNeverOpens() async throws {
            let failure = SerialStreamError.openFailed(path: "/dev/none", code: 2)
            try await withRig(openFailure: failure, open: false) { rig in
                let error = await errorOf { try await rig.channel.open() }

                XCTAssertEqual(error as? SerialChannelError, .closed(.failed(failure)))
                let isOpen = await rig.channel.isOpen
                XCTAssertFalse(isOpen)
                let requestError = await errorOf { try await rig.channel.request(exchange(1, "1")) }
                let sendError = await errorOf { try await rig.channel.send(ascii("w")) }
                XCTAssertEqual(requestError as? SerialChannelError, .notOpen)
                XCTAssertEqual(sendError as? SerialChannelError, .notOpen)
                await settle(0.1)
                await rig.recorder.expectTags([.closed(.failed(failure))])
                XCTAssertEqual(rig.stream.writes, [])
            }
        }

        func testAnOpenFailureCanBeRetried() async throws {
            let failure = SerialStreamError.openFailed(path: "/dev/none", code: 2)
            let rig = await ManualRig()
            let first = await rig.beginOpening()
            rig.stream.completeClose(.failed(failure))
            let firstError = await errorOf { try await first.value }

            XCTAssertEqual(firstError as? SerialChannelError, .closed(.failed(failure)))
            try await rig.open()
            let isOpen = await rig.channel.isOpen
            XCTAssertTrue(isOpen)
            await rig.recorder.expectTags([.closed(.failed(failure)), .opened])
            await rig.shutDown()
        }

        func testRequestsAndWritesWhenTheChannelIsNotOpenThrowNotOpen() async throws {
            try await withRig(open: false) { rig in
                let beforeRequest = await errorOf { try await rig.channel.request(exchange(1, "1")) }
                let beforeSend = await errorOf { try await rig.channel.send(ascii("w")) }
                let beforeFrame = await errorOf { try await rig.channel.request(ascii("q"), reply: .anything) }
                XCTAssertEqual(beforeRequest as? SerialChannelError, .notOpen)
                XCTAssertEqual(beforeSend as? SerialChannelError, .notOpen)
                XCTAssertEqual(beforeFrame as? SerialChannelError, .notOpen)

                try await rig.channel.open()
                await rig.channel.close()

                let afterRequest = await errorOf { try await rig.channel.request(exchange(2, "2")) }
                let afterSend = await errorOf { try await rig.channel.send(ascii("w")) }
                XCTAssertEqual(afterRequest as? SerialChannelError, .notOpen)
                XCTAssertEqual(afterSend as? SerialChannelError, .notOpen)
                await settle(0.2)
                XCTAssertEqual(rig.stream.writes, [])
                // Nothing sent while the channel was not open is kept to be sent when it opens.
                try await rig.channel.open()
                await settle(0.2)
                XCTAssertEqual(rig.stream.writes, [])
                await rig.recorder.expectTags([.opened, .closed(.requested), .opened])
            }
        }

        func testCloseThenReopenWorksAgainAndNothingFromBeforeTheCloseLeaksIn() async throws {
            try await withRig(script: [.reply(with: [ReplayChunk(ascii("OLD"), at: 0.3)])]) { rig in
                let first = Task { try await rig.channel.request(exchange(1, "1", timeout: 0.2)) }
                await waitUntil { rig.stream.writes.count == 1 }
                let second = Task { try await rig.channel.request(exchange(2, "2")) }
                await waitUntil { await queuedCount(of: rig.channel) == 1 }

                await rig.channel.close()
                let isClosed = await !rig.channel.isOpen
                XCTAssertTrue(isClosed)
                rig.stream.append([.reply(with: [ReplayChunk(ascii("N"), at: 0.5)])])
                try await rig.channel.open()
                let isOpen = await rig.channel.isOpen
                XCTAssertTrue(isOpen)
                let reply = try await rig.channel.request(exchange(3, "3", timeout: 5))

                // Neither the first request's timer (0.2 s) nor its reply (0.3 s) reached the new one.
                XCTAssertEqual(reply, ascii("N"))
                let firstError = await errorOf { try await first.value }
                let secondError = await errorOf { try await second.value }
                XCTAssertEqual(firstError as? SerialChannelError, .closed(.requested))
                XCTAssertEqual(secondError as? SerialChannelError, .closed(.requested))
                XCTAssertEqual(rig.writtenFrames, [ascii("1"), ascii("3")])
                XCTAssertFalse(rig.recorder.has(.timedOut(1)))
                XCTAssertFalse(rig.recorder.has(.timedOut(3)))
                await rig.recorder.expectTagsWithoutRaw(
                    [.opened, .sent(1), .closed(.requested), .opened, .sent(3), .answered(3)]
                )
            }
        }

        func testAStreamsLateReportOfTheCloseTheChannelAskedForDoesNotEndTheNextOpen() async throws {
            let rig = await ManualRig()
            try await rig.open()
            await rig.channel.close()
            let reopening = await rig.beginOpening()

            // The stream reports the close the channel asked for after the next open has begun.
            rig.stream.completeClose(.requested)
            rig.stream.completeOpen()
            try await reopening.value

            let isOpen = await rig.channel.isOpen
            XCTAssertTrue(isOpen)
            await rig.recorder.expectTags([.opened, .closed(.requested), .opened])
            await rig.shutDown()
        }

        func testClosingAndOpeningAgainInsideThePauseAfterATimeoutLeavesTheNewSessionFree() async throws {
            let script: [ReplayStep] = [.silence()]
            try await withRig(script: script, gap: 5) { rig in
                let first = Task { try await rig.channel.request(exchange(1, "1", timeout: 0.05)) }
                _ = await errorOf { try await first.value }
                await waitUntil { rig.recorder.has(.timedOut(1)) }

                await rig.channel.close()
                rig.stream.append([.reply(with: [ReplayChunk(ascii("N"), at: 0.01)])])
                try await rig.channel.open()
                let started = Date()
                let reply = try await rig.channel.request(exchange(2, "2", timeout: 1))

                // The pause of the old session (5 s) does not hold back the new one.
                XCTAssertEqual(reply, ascii("N"))
                XCTAssertLessThan(Date().timeIntervalSince(started), 2)
                await rig.recorder.expectTagsWithoutRaw(
                    [.opened, .sent(1), .timedOut(1), .closed(.requested), .opened, .sent(2), .answered(2)]
                )
            }
        }

        // MARK: A stream that opens late

        func testOpenWaitsForAStreamThatOpensLaterAndAnotherOpenWaitsWithIt() async throws {
            let rig = await ManualRig()
            let finished = Flag()
            let first = Task {
                try await rig.channel.open()
                finished.raise()
            }
            await waitUntil { rig.stream.openCalls == 1 }
            let second = Task { try await rig.channel.open() }
            await settle(0.1)

            XCTAssertFalse(finished.isRaised)
            var isOpen = await rig.channel.isOpen
            XCTAssertFalse(isOpen)
            XCTAssertEqual(rig.stream.openCalls, 1)

            rig.stream.completeOpen()
            try await first.value
            try await second.value

            isOpen = await rig.channel.isOpen
            XCTAssertTrue(isOpen)
            XCTAssertEqual(rig.stream.openCalls, 1)
            await rig.recorder.expectTags([.opened])
            await rig.shutDown()
        }

        func testARequestWhileTheChannelIsOpeningThrowsNotOpen() async throws {
            let rig = await ManualRig()
            let opening = await rig.beginOpening()

            let error = await errorOf { try await rig.channel.request(exchange(1, "1")) }

            XCTAssertEqual(error as? SerialChannelError, .notOpen)
            rig.stream.completeOpen()
            try await opening.value
            XCTAssertEqual(rig.stream.writes, [])
            await rig.shutDown()
        }

        func testAnOpenReportedTwiceOpensTheChannelOnce() async throws {
            let rig = await ManualRig()
            try await rig.open()

            rig.stream.completeOpen()
            await settle(0.1)

            let isOpen = await rig.channel.isOpen
            XCTAssertTrue(isOpen)
            XCTAssertEqual(rig.stream.closeCalls, 0)
            await rig.recorder.expectTags([.opened])
            await rig.shutDown()
        }

        func testClosingWhileOpeningEndsTheOpenAtOnceAndTheChannelIsNotStuck() async throws {
            let rig = await ManualRig()
            let opening = await rig.beginOpening()

            await rig.channel.close()
            let error = await errorOf { try await opening.value }

            XCTAssertEqual(error as? SerialChannelError, .closed(.requested))
            XCTAssertEqual(rig.stream.closeCalls, 1)
            let isOpen = await rig.channel.isOpen
            XCTAssertFalse(isOpen)
            await rig.recorder.expectTags([.closed(.requested)])

            // The channel opens again.
            try await rig.open()
            XCTAssertEqual(rig.stream.openCalls, 2)
            await rig.recorder.expectTags([.closed(.requested), .opened])
            await rig.shutDown()
        }

        func testClosingWhileOpeningReportsOnceWhenTheStreamReportsTheCloseToo() async throws {
            let rig = await ManualRig()
            rig.stream.closeReport = .requested
            let opening = await rig.beginOpening()

            await rig.channel.close()
            rig.stream.completeClose(.requested)
            let error = await errorOf { try await opening.value }
            await settle(0.1)

            XCTAssertEqual(error as? SerialChannelError, .closed(.requested))
            await rig.recorder.expectTags([.closed(.requested)])
            await rig.shutDown()
        }

        func testAnOpenThatCompletesAfterTheChannelWasClosedClosesTheStreamAgain() async throws {
            let rig = await ManualRig()
            let opening = await rig.beginOpening()
            await rig.channel.close()
            _ = await opening.result

            rig.stream.completeOpen()
            await waitUntil { rig.stream.closeCalls == 2 }

            let isOpen = await rig.channel.isOpen
            XCTAssertFalse(isOpen)
            // What the stream reports for that second close changes nothing.
            rig.stream.completeClose(.requested)
            await settle(0.1)
            await rig.recorder.expectTags([.closed(.requested)])
            XCTAssertEqual(rig.stream.openCalls, 1)
            await rig.shutDown()
        }

        func testAnOpenThatCompletesWhileTheChannelIsClosedAndOpeningAgainStillOpensIt() async throws {
            let rig = await ManualRig()
            let first = await rig.beginOpening()
            await rig.channel.close()
            _ = await first.result
            let second = await rig.beginOpening()

            // The first open completes late: the stream is open, and that is what the second wants.
            rig.stream.completeOpen()
            try await second.value

            let isOpen = await rig.channel.isOpen
            XCTAssertTrue(isOpen)
            await rig.shutDown()
        }

        func testWhatTheStreamReportsFromInsideACloseDoesNotTouchTheNextSession() async throws {
            // The stream reports the close from inside the call, and that report may still be on its way to
            // the channel when the next session begins: it is the old session's, and the open goes on.
            for iteration in 0..<25 {
                let rig = await ManualRig()
                rig.stream.closeReport = .requested
                try await rig.open()
                let pending = Task { try await rig.channel.request(exchange(1, "1")) }
                await waitUntil { rig.recorder.has(.sent(1)) }

                let finished = Flag()
                let reopening = Task {
                    await rig.channel.close()
                    try await rig.channel.open()
                    finished.raise()
                }
                await waitUntil { rig.stream.openCalls == 2 }
                await settle(0.05)

                XCTAssertFalse(finished.isRaised, "iteration \(iteration)")
                rig.stream.completeOpen()
                try await reopening.value
                let isOpen = await rig.channel.isOpen
                XCTAssertTrue(isOpen, "iteration \(iteration)")
                let error = await errorOf { try await pending.value }
                XCTAssertEqual(error as? SerialChannelError, .closed(.requested), "iteration \(iteration)")
                await rig.recorder.expectTags([.opened, .sent(1), .closed(.requested), .opened])
                await rig.shutDown()
            }
        }

        func testChannelsWithAnEventsConsumerCanBeReleasedAndMadeAgainInQuickSuccession() async throws {
            // A lost wake-up in the concurrency runtime of Swift 5.5 hung this; it is the reason for the
            // minimum of Swift 5.7 (see CONTRIBUTING.md).
            let finished = await completes(within: 20) {
                for _ in 0..<100 {
                    let stream = ManualByteStream()
                    let channel = SerialChannel(stream: stream)
                    let events = await channel.events()
                    _ = Task {
                        for await _ in events {}
                    }
                    let opening = Task { try await channel.open() }
                    while stream.openCalls == 0 {
                        await Task.yield()
                    }
                    stream.completeOpen()
                    try? await opening.value
                    await channel.close()
                }
            }

            XCTAssertTrue(finished, "channels with a consumer of their events could not be released and made again")
        }

        func testOpeningAndClosingFromTwoTasksNeverLeavesTheChannelStuck() async throws {
            for iteration in 0..<100 {
                let stream = SimulatedByteStream(device: silentDevice, replyLatency: 0)
                let channel = SerialChannel(stream: stream)
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { try? await channel.open() }
                    group.addTask { await channel.close() }
                }

                await channel.close()
                var isOpen = await channel.isOpen
                XCTAssertFalse(isOpen, "iteration \(iteration)")
                XCTAssertFalse(stream.isOpen, "iteration \(iteration)")
                try await channel.open()
                isOpen = await channel.isOpen
                XCTAssertTrue(isOpen, "iteration \(iteration)")
                XCTAssertTrue(stream.isOpen, "iteration \(iteration)")
                await channel.close()
            }
        }
    }

#endif
