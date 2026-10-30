//
//  SerialChannelStressTests.swift
//  SerialPortSwiftConcurrencyTests
//
//  Many tasks at once, cancelling at random moments and, in the second test, a channel that is closed and
//  opened under them. The numbers are drawn from a generator with a fixed seed, so a failure repeats the
//  same requests, if not the same interleaving. What must hold whatever the interleaving: every task comes
//  back, no request gets another's reply, and the exchanges on the wire never overlap.
//

#if compiler(>=5.7) && canImport(_Concurrency)

    import Foundation
    import SerialPortSwift
    import SerialPortSwiftConcurrency
    import SerialPortSwiftSimulation
    import XCTest

    /// A small deterministic generator (SplitMix64), so the stress is the same on every run.
    private struct SplitMix {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }

        mutating func below(_ bound: Int) -> Int {
            return Int(next() % UInt64(bound))
        }
    }

    @available(macOS 10.15, *)
    final class SerialChannelStressTests: XCTestCase {
        /// Answers a frame with the same frame, its first byte turned into "r"; a frame that starts with "W"
        /// is a write, and gets no answer.
        private func echoDevice() -> ScriptedDevice {
            return ScriptedDevice { frame in
                if frame.first == UInt8(ascii: "W") {
                    return nil
                }
                var reply = frame
                reply[reply.startIndex] = UInt8(ascii: "r")
                return reply
            }
        }

        /// Exchanges on the wire never overlap in the events: `sent(n)`, then `answered(n)` or `timedOut(n)`,
        /// then the next `sent`.
        private func assertSerial(_ tags: [Tag], file: StaticString = #file, line: UInt = #line) {
            var onTheWire: Int?
            for tag in tags {
                switch tag {
                case .sent(let number?):
                    XCTAssertNil(onTheWire, "sent(\(number)) while \(String(describing: onTheWire)) is on the wire", file: file, line: line)
                    onTheWire = number
                case .answered(let number), .timedOut(let number):
                    XCTAssertEqual(onTheWire, number, "\(tag) while \(String(describing: onTheWire)) is on the wire", file: file, line: line)
                    onTheWire = nil
                case .closed:
                    onTheWire = nil
                default:
                    break
                }
            }
        }

        func testManyTasksCancellingAtRandomMomentsAreAllAnsweredOrCancelledAndTheWireStaysSerial() async throws {
            for round in 0..<6 {
                let stream = SimulatedByteStream(device: echoDevice(), replyLatency: 0.002)
                let configuration = SerialChannel.Configuration(defaultTimeout: 2, maximumReplyLength: 64, postTimeoutGap: 0)
                let channel = SerialChannel(stream: stream, configuration: configuration)
                let recorder = await EventRecorder.attach(to: channel)
                try await channel.open()
                var random = SplitMix(state: UInt64(round) &+ 77)
                let count = 120
                let delays = (0..<count).map { _ in random.below(25) }
                let cancels = (0..<count).map { _ in random.below(3) == 0 }
                // 0 is a write without a reply, the rest are requests.
                let kinds = (0..<count).map { _ in random.below(4) }
                let results = Box<[String]>([])

                let everyone = Task { () -> Void in
                    await withTaskGroup(of: Void.self) { group in
                        for number in 0..<count {
                            group.addTask {
                                let frame = ascii(String(format: kinds[number] == 0 ? "W%03d" : "Q%03d", number))
                                let work = Task { () -> String in
                                    do {
                                        if kinds[number] == 0 {
                                            try await channel.send(frame)
                                            return "sent"
                                        }
                                        let reply = try await channel.request(SerialExchange(id: id(number), frame: frame, reply: .exactly(4)))
                                        return reply == ascii(String(format: "r%03d", number)) ? "answered" : "WRONG \(reply)"
                                    } catch is CancellationError {
                                        return "cancelled"
                                    } catch {
                                        return "\(error)"
                                    }
                                }
                                if cancels[number] {
                                    try? await Task.sleep(nanoseconds: UInt64(delays[number]) * 1_000_000)
                                    work.cancel()
                                }
                                let result = await work.value
                                results.mutate { $0.append(result) }
                            }
                        }
                    }
                }
                let finished = await completes(within: 20) { await everyone.value }

                XCTAssertTrue(finished, "round \(round): some task never came back; \(results.value.count) of \(count) did")
                XCTAssertEqual(results.value.filter { $0.hasPrefix("WRONG") }, [], "round \(round)")
                await channel.waitUntilIdle()
                await settle(0.05)
                assertSerial(recorder.tagsWithoutRaw)
                let queued = await queuedCount(of: channel)
                XCTAssertEqual(queued, 0, "round \(round)")
                await channel.close()
                recorder.stop()
            }
        }

        func testManyTasksAskingWhileTheChannelIsClosedAndOpenedAgainNobodyIsLeftWaitingAndNoReplyIsWrong() async throws {
            for round in 0..<4 {
                let stream = SimulatedByteStream(device: echoDevice(), replyLatency: 0.002)
                let configuration = SerialChannel.Configuration(defaultTimeout: 0.3, maximumReplyLength: 64, postTimeoutGap: 0.01)
                let channel = SerialChannel(stream: stream, configuration: configuration)
                let recorder = await EventRecorder.attach(to: channel)
                try await channel.open()
                let stop = Flag()
                let chaos = Task {
                    var random = SplitMix(state: UInt64(round) &+ 5)
                    while !stop.isRaised {
                        try? await Task.sleep(nanoseconds: UInt64(15 + random.below(30)) * 1_000_000)
                        if random.below(2) == 0 {
                            await channel.close()
                            try? await Task.sleep(nanoseconds: 5_000_000)
                        }
                        try? await channel.open()
                    }
                }
                let results = Box<[String]>([])
                let workers = 8
                let perWorker = 40

                let everyone = Task { () -> Void in
                    await withTaskGroup(of: Void.self) { group in
                        for worker in 0..<workers {
                            group.addTask {
                                var random = SplitMix(state: UInt64(worker * 100 + round))
                                for number in 0..<perWorker {
                                    let frame = ascii(String(format: "Q%d%02d", worker, number))
                                    let work = Task { () -> String in
                                        do {
                                            let reply = try await channel.request(frame, reply: .exactly(4))
                                            return reply == ascii(String(format: "r%d%02d", worker, number)) ? "answered" : "WRONG \(reply)"
                                        } catch is CancellationError {
                                            return "cancelled"
                                        } catch {
                                            return "\(error)"
                                        }
                                    }
                                    if random.below(4) == 0 {
                                        try? await Task.sleep(nanoseconds: UInt64(random.below(6)) * 1_000_000)
                                        work.cancel()
                                    }
                                    let result = await work.value
                                    results.mutate { $0.append(result) }
                                }
                            }
                        }
                    }
                }
                let finished = await completes(within: 40) { await everyone.value }
                stop.raise()
                _ = await chaos.value

                XCTAssertTrue(finished, "round \(round): some task never came back; \(results.value.count) of \(workers * perWorker) did")
                XCTAssertEqual(results.value.filter { $0.hasPrefix("WRONG") }, [], "round \(round)")
                await settle(0.05)
                assertSerial(recorder.tagsWithoutRaw)
                await channel.close()
                recorder.stop()
            }
        }
    }

#endif
