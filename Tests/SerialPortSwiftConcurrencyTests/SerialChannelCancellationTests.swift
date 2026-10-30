//
//  SerialChannelCancellationTests.swift
//  SerialPortSwiftConcurrencyTests
//
//  Cancelling the task of a request, waiting for the channel to be idle, and watching its events.
//

#if compiler(>=5.7) && canImport(_Concurrency)

    import SerialPortSwift
    import SerialPortSwiftConcurrency
    import SerialPortSwiftSimulation
    import XCTest

    @available(macOS 10.15, *)
    final class SerialChannelCancellationTests: XCTestCase {
        // MARK: Cancelling

        func testCancellingAQueuedRequestRemovesItAndTheNextOneGoesOut() async throws {
            try await withRig(script: [.silence(), .silence()]) { rig in
                let first = Task { try await rig.channel.request(exchange(1, "1")) }
                await waitUntil { rig.stream.writes.count == 1 }
                let second = Task { try await rig.channel.request(exchange(2, "2")) }
                await waitUntil { await queuedCount(of: rig.channel) == 1 }
                let third = Task { try await rig.channel.request(exchange(3, "3")) }
                await waitUntil { await queuedCount(of: rig.channel) == 2 }

                second.cancel()
                let secondError = await errorOf { try await second.value }

                XCTAssertTrue(secondError is CancellationError, "\(String(describing: secondError))")
                await waitUntil { await queuedCount(of: rig.channel) == 1 }
                await waitUntil { rig.recorder.has(.cancelled([2])) }

                rig.stream.receive(ascii("A"))
                await waitUntil { rig.recorder.has(.sent(3)) }
                rig.stream.receive(ascii("C"))
                let firstReply = try await first.value
                let thirdReply = try await third.value

                XCTAssertEqual(firstReply, ascii("A"))
                XCTAssertEqual(thirdReply, ascii("C"))
                // The cancelled request was never written.
                XCTAssertEqual(rig.writtenFrames, [ascii("1"), ascii("3")])
                await rig.recorder.expectTagsWithoutRaw(
                    [.opened, .sent(1), .cancelled([2]), .answered(1), .sent(3), .answered(3)]
                )
            }
        }

        func testARequestCancelledWhileTheOneAheadOfItIsBeingAnsweredIsNeverWritten() async throws {
            // The channel scans the reply to "1" on its actor, and the cancellation happens inside the scan:
            // `cancel()` has returned, and the channel has not yet been asked to take "2" out of the queue (that
            // needs the actor, which is busy), when it looks at what is next in line.
            let doomed = Box<Task<Data, Error>?>(nil)
            let rig = await ManualRig(matcher: HookedMatcher { doomed.value?.cancel() })
            try await rig.open()
            let first = Task { try await rig.channel.request(exchange(1, "1")) }
            await waitUntil { rig.stream.writes.count == 1 }
            let second = Task { try await rig.channel.request(exchange(2, "2", timeout: 0.3)) }
            await waitUntil { await queuedCount(of: rig.channel) == 1 }
            doomed.value = second

            rig.stream.deliver(ascii("A"))
            let firstReply = try await first.value
            let error = await errorOf { try await second.value }
            await settle(0.1)

            XCTAssertEqual(firstReply, ascii("A"))
            XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
            XCTAssertEqual(rig.stream.writes, [ascii("1")])
            await rig.recorder.expectTagsWithoutRaw([.opened, .sent(1), .answered(1), .cancelled([2])])
            await rig.shutDown()
        }

        func testACancelledRequestOnTheWireIsLeftToItsReplyAndHoldsTheWireUntilThen() async throws {
            try await withRig(script: [.silence(), .silence()]) { rig in
                let first = Task { try await rig.channel.request(exchange(1, "1")) }
                await waitUntil { rig.recorder.has(.sent(1)) }
                let second = Task { try await rig.channel.request(exchange(2, "2")) }
                await waitUntil { await queuedCount(of: rig.channel) == 1 }

                first.cancel()
                await settle(0.2)

                // Cancelled, yet still on the wire: the next request waits for its reply.
                XCTAssertFalse(rig.recorder.has(.sent(2)))
                rig.stream.receive(ascii("A"))
                let firstReply = try await first.value
                await waitUntil { rig.recorder.has(.sent(2)) }
                rig.stream.receive(ascii("B"))
                let secondReply = try await second.value

                XCTAssertEqual(firstReply, ascii("A"))
                XCTAssertEqual(secondReply, ascii("B"))
                await rig.recorder.expectTagsWithoutRaw([.opened, .sent(1), .answered(1), .sent(2), .answered(2)])
            }
        }

        func testACancelledRequestOnTheWireThatTimesOutThrowsTheTimeoutNotTheCancellation() async throws {
            try await withRig(script: [.silence()]) { rig in
                let pending = Task { try await rig.channel.request(exchange(1, "1", timeout: 0.2)) }
                await waitUntil { rig.recorder.has(.sent(1)) }

                pending.cancel()
                let error = await errorOf { try await pending.value }

                XCTAssertEqual(error as? SerialChannelError, .timedOut)
            }
        }

        func testASendCancelledBeforeItsTurnThrowsCancellationAndIsNeverWritten() async throws {
            try await withRig(script: [.silence()]) { rig in
                let first = Task { try await rig.channel.request(exchange(1, "1")) }
                await waitUntil { rig.stream.writes.count == 1 }
                let write = Task { try await rig.channel.send(ascii("w")) }
                await waitUntil { await queuedCount(of: rig.channel) == 1 }

                write.cancel()
                let error = await errorOf { try await write.value }
                rig.stream.receive(ascii("A"))
                _ = try await first.value
                await settle(0.1)

                XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
                XCTAssertEqual(rig.writtenFrames, [ascii("1")])
                // A write has no id: nothing is published for its cancellation.
                await rig.recorder.expectTagsWithoutRaw([.opened, .sent(1), .answered(1)])
            }
        }

        func testATaskThatWasCancelledBeforeItAsksWritesNothing() async throws {
            try await withRig(script: [.silence()]) { rig in
                let asking = Task { () -> (request: Error?, send: Error?) in
                    while !Task.isCancelled {
                        await Task.yield()
                    }
                    let requestError = await errorOf { try await rig.channel.request(exchange(1, "1")) }
                    let sendError = await errorOf { try await rig.channel.send(ascii("w")) }
                    return (requestError, sendError)
                }

                asking.cancel()
                let errors = await asking.value
                await settle(0.1)

                XCTAssertTrue(errors.request is CancellationError)
                XCTAssertTrue(errors.send is CancellationError)
                XCTAssertEqual(rig.stream.writes, [])
                await rig.recorder.expectTags([.opened])
            }
        }

        func testCancellingARequestThatWasAnsweredChangesNothing() async throws {
            try await withRig(script: [.reply(with: [ReplayChunk(ascii("A"), at: 0.01)])]) { rig in
                let request = Task { try await rig.channel.request(exchange(1, "1")) }
                let reply = try await request.value
                request.cancel()
                await settle(0.05)

                XCTAssertEqual(reply, ascii("A"))
                await rig.recorder.expectTagsWithoutRaw([.opened, .sent(1), .answered(1)])
            }
        }

        // MARK: Waiting until idle

        func testWaitUntilIdleReturnsAtOnceWhenNothingIsQueued() async throws {
            try await withRig { rig in
                let channel = rig.channel
                let returned = await completes { await channel.waitUntilIdle() }

                XCTAssertTrue(returned)
            }
        }

        func testWaitUntilIdleWaitsUntilTheChannelHasDrained() async throws {
            try await withRig(script: [.silence(), .silence()]) { rig in
                let first = Task { try await rig.channel.request(exchange(1, "1")) }
                await waitUntil { rig.stream.writes.count == 1 }
                let write = Task { try await rig.channel.send(ascii("w")) }
                await waitUntil { await queuedCount(of: rig.channel) == 1 }
                let idle = Flag()
                let channel = rig.channel
                Task {
                    await channel.waitUntilIdle()
                    idle.raise()
                }
                await settle(0.2)

                XCTAssertFalse(idle.isRaised)

                rig.stream.receive(ascii("A"))
                _ = try await first.value
                try await write.value
                await waitUntil { idle.isRaised }
                // The stream notes a write a moment after the channel makes it.
                await waitUntil { rig.stream.writes.count == 2 }

                // The write behind the exchange went out before the channel was idle.
                XCTAssertEqual(rig.writtenFrames, [ascii("1"), ascii("w")])
            }
        }

        func testWaitUntilIdleReturnsWhileACallerKeepsPolling() async throws {
            let rounds = 8
            let step = ReplayStep.reply(with: [ReplayChunk(ascii("A"), at: 0.03)])
            try await withRig(script: Array(repeating: step, count: rounds)) { rig in
                let answered = Box(0)
                let poller = Task {
                    for number in 1...rounds {
                        _ = try await rig.channel.request(exchange(number, "q"))
                        answered.value = number
                    }
                }
                await waitUntil { rig.recorder.has(.sent(1)) }

                let channel = rig.channel
                let answeredWhenIdle = Box<Int?>(nil)
                let returned = await completes(within: 5) {
                    await channel.waitUntilIdle()
                    answeredWhenIdle.value = answered.value
                }
                try await poller.value

                // Each round leaves a moment with nothing queued and nothing on the wire: the first one will
                // do, however busy the poller keeps the channel after it.
                XCTAssertTrue(returned)
                XCTAssertLessThan(answeredWhenIdle.value ?? rounds, rounds - 1)
            }
        }

        func testWaitUntilIdleReturnsOnAChannelThatIsClosed() async throws {
            try await withRig(open: false) { rig in
                let channel = rig.channel
                let neverOpened = await completes { await channel.waitUntilIdle() }
                try await channel.open()
                await channel.close()
                let afterClose = await completes { await channel.waitUntilIdle() }

                XCTAssertTrue(neverOpened)
                XCTAssertTrue(afterClose)
            }
        }

        func testWaitUntilIdleReturnsWhenTheChannelIsClosedWhileItWaits() async throws {
            try await withRig(script: [.silence()]) { rig in
                let pending = Task { try await rig.channel.request(exchange(1, "1")) }
                await waitUntil { rig.recorder.has(.sent(1)) }
                let idle = Flag()
                let channel = rig.channel
                Task {
                    await channel.waitUntilIdle()
                    idle.raise()
                }
                await settle(0.1)
                XCTAssertFalse(idle.isRaised)

                await rig.channel.close()

                await waitUntil { idle.isRaised }
                let error = await errorOf { try await pending.value }
                XCTAssertEqual(error as? SerialChannelError, .closed(.requested))
            }
        }

        func testWaitUntilIdleReturnsAfterATimeoutThatEmptiesTheQueueWithoutWaitingOutTheGap() async throws {
            try await withRig(script: [.silence()], gap: 3) { rig in
                let channel = rig.channel
                let request = Task { try await channel.request(exchange(1, "1", timeout: 0.05)) }
                await waitUntil { rig.recorder.has(.sent(1)) }

                let returned = await completes(within: 1.5) { await channel.waitUntilIdle() }
                let error = await errorOf { try await request.value }

                XCTAssertTrue(returned)
                XCTAssertEqual(error as? SerialChannelError, .timedOut)
                XCTAssertFalse(rig.recorder.has(.sent(2)))
            }
        }

        func testCancellingTheRequestsQueuedBehindAPauseMakesTheChannelIdleAtOnce() async throws {
            // The pause is far longer than the wait, so only the cancellation can wake the waiter in time.
            try await withRig(script: [.silence(), .silence()], gap: 30) { rig in
                let first = Task { try await rig.channel.request(exchange(1, "1", timeout: 0.05)) }
                await waitUntil { rig.stream.writes.count == 1 }
                let second = Task { try await rig.channel.request(exchange(2, "2")) }
                await waitUntil { await queuedCount(of: rig.channel) == 1 }
                _ = await errorOf { try await first.value }
                let idle = Flag()
                let channel = rig.channel
                Task {
                    await channel.waitUntilIdle()
                    idle.raise()
                }
                await waitUntil { await idleWaiterCount(of: channel) == 1 }
                await settle(0.1)
                XCTAssertFalse(idle.isRaised)

                second.cancel()
                let error = await errorOf { try await second.value }

                XCTAssertTrue(error is CancellationError)
                let woke = await waitUntil(timeout: 1, report: false) { idle.isRaised }
                XCTAssertTrue(woke, "the cancellation did not wake the one who waits for the channel to be idle")
                XCTAssertFalse(rig.recorder.has(.sent(2)))
            }
        }

        func testACancelledWaitUntilIdleReturnsAndLeavesNothingBehind() async throws {
            try await withRig(script: [.silence()]) { rig in
                let pending = Task { try await rig.channel.request(exchange(1, "1")) }
                await waitUntil { rig.recorder.has(.sent(1)) }
                let channel = rig.channel
                let waiter = Task { await channel.waitUntilIdle() }
                await waitUntil { await idleWaiterCount(of: channel) == 1 }
                await settle(0.1)

                // Busy, and cancelled: it does not wait.
                waiter.cancel()
                let returned = await completes { await waiter.value }

                XCTAssertTrue(returned)
                await waitUntil { await idleWaiterCount(of: channel) == 0 }
                rig.stream.receive(ascii("A"))
                _ = try await pending.value
            }
        }

        func testWaitUntilIdleInATaskThatWasCancelledBeforeItWaitsReturnsAtOnceAndLeavesNothingBehind() async throws {
            try await withRig(script: [.silence()]) { rig in
                let pending = Task { try await rig.channel.request(exchange(1, "1")) }
                await waitUntil { rig.recorder.has(.sent(1)) }
                let channel = rig.channel
                let waiter = Task { () -> Void in
                    while !Task.isCancelled {
                        await Task.yield()
                    }
                    await channel.waitUntilIdle()
                }

                waiter.cancel()
                let returned = await completes { await waiter.value }

                XCTAssertTrue(returned)
                await waitUntil { await idleWaiterCount(of: channel) == 0 }
                rig.stream.receive(ascii("A"))
                _ = try await pending.value
            }
        }

        // MARK: Events

        func testEveryConsumerOfEventsReceivesEveryEventInTheSameOrder() async throws {
            try await withRig(script: [.reply(with: [ReplayChunk(ascii("A"), at: 0.02)])], open: false) { rig in
                let second = await EventRecorder.attach(to: rig.channel)
                let third = await EventRecorder.attach(to: rig.channel)
                try await rig.channel.open()

                _ = try await rig.channel.request(exchange(1, "1"))
                await waitUntil { second.has(.answered(1)) && third.has(.answered(1)) && rig.recorder.has(.answered(1)) }

                XCTAssertEqual(second.tags, [.opened, .sent(1), .raw, .answered(1)])
                XCTAssertEqual(second.events, rig.recorder.events)
                XCTAssertEqual(third.events, rig.recorder.events)
                second.stop()
                third.stop()
            }
        }

        func testAConsumerOnlySeesWhatHappensAfterItAsked() async throws {
            try await withRig(script: [.silence()]) { rig in
                let late = await EventRecorder.attach(to: rig.channel)

                await rig.channel.close()

                await late.expectTags([.closed(.requested)])
                await rig.recorder.expectTags([.opened, .closed(.requested)])
                late.stop()
            }
        }

        func testAConsumerThatStopsIsRemovedAndTheOthersCarryOn() async throws {
            try await withRig { rig in
                let leaving = await EventRecorder.attach(to: rig.channel)
                let remaining = await eventConsumerCount(of: rig.channel)
                XCTAssertEqual(remaining, 2)

                leaving.stop()
                await waitForEventConsumers(1, of: rig.channel)

                await rig.channel.close()
                await rig.recorder.expectTags([.opened, .closed(.requested)])
                XCTAssertFalse(leaving.has(.closed(.requested)))
            }
        }

        func testAConsumerThatLeavesTheLoopIsRemovedToo() async throws {
            try await withRig { rig in
                let channel = rig.channel
                let first = Task { () -> SerialQueueEvent.Kind? in
                    for await event in await channel.events() {
                        return event.kind
                    }
                    return nil
                }
                await waitUntil { await eventConsumerCount(of: channel) == 2 }

                await channel.close()
                let kind = await first.value

                XCTAssertEqual(kind, .closed(.requested))
                await waitForEventConsumers(1, of: channel)
            }
        }

        func testTheEventsEndWhenTheChannelIsReleased() async throws {
            let recorder: EventRecorder
            weak var released: SerialChannel?
            do {
                let channel = SerialChannel(stream: ReplayByteStream())
                released = channel
                recorder = await EventRecorder.attach(to: channel)
                try await channel.open()
                await channel.close()
            }

            await waitUntil { released == nil }
            let ended = await completes { await recorder.waitUntilEnded() }

            XCTAssertNil(released)
            XCTAssertTrue(ended)
            XCTAssertEqual(recorder.tags, [.opened, .closed(.requested)])
        }

        // MARK: Many at once

        func testManyConcurrentRequestsAreAllAnsweredOnceEachWithItsOwnReply() async throws {
            let device = ScriptedDevice { frame in
                var reply = frame
                reply[reply.startIndex] = UInt8(ascii: "r")
                return reply
            }
            let stream = SimulatedByteStream(device: device, replyLatency: 0.001)
            let channel = SerialChannel(stream: stream, configuration: SerialChannel.Configuration(defaultTimeout: 5))
            let recorder = await EventRecorder.attach(to: channel)
            try await channel.open()
            let count = 60

            let replies = try await withThrowingTaskGroup(of: (Int, Data).self) { group -> [Int: Data] in
                for number in 0..<count {
                    group.addTask {
                        let frame = ascii(String(format: "Q%02d", number))
                        return (number, try await channel.request(frame, reply: .exactly(3)))
                    }
                }
                var collected: [Int: Data] = [:]
                for try await (number, reply) in group {
                    collected[number] = reply
                }
                return collected
            }

            for number in 0..<count {
                XCTAssertEqual(replies[number], ascii(String(format: "r%02d", number)))
            }
            await waitUntil { recorder.tags.filter { if case .answered = $0 { return true } else { return false } }.count == count }
            let sent = recorder.events.compactMap { event -> Data? in
                if case .sent = event.kind { return event.bytes } else { return nil }
            }
            XCTAssertEqual(sent.count, count)
            XCTAssertEqual(Set(sent).count, count)
            // One exchange on the wire at a time: nothing arrived with no one waiting, nothing timed out.
            XCTAssertFalse(recorder.has(.unsolicited))
            XCTAssertFalse(recorder.tags.contains { if case .timedOut = $0 { return true } else { return false } })
            let remaining = await queuedCount(of: channel)
            XCTAssertEqual(remaining, 0)
            await channel.close()
            recorder.stop()
        }
    }

#endif
