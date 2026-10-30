//
//  PortAndChannelTests.swift
//  SerialPortSwiftConcurrencyTests
//
//  A real `PosixSerialPort` on a `PseudoTerminal`, under a real `SerialChannel`: the pieces together,
//  with the test playing the device on the other end of the line.
//

#if compiler(>=5.5) && canImport(_Concurrency)

    import Foundation
    import SerialPortSwift
    import SerialPortSwiftConcurrency
    import SerialPortSwiftSimulation
    import XCTest

    /// The device on the far end of a pseudo-terminal. It reads and writes on queues of its own, so the
    /// cooperative threads the channel runs on are never blocked by it.
    @available(macOS 10.15, *)
    private final class FarEnd: @unchecked Sendable {
        let terminal: PseudoTerminal
        private let queue = DispatchQueue(label: "PortAndChannelTests.device")

        init() throws {
            terminal = try PseudoTerminal()
        }

        /// Reads `count` bytes from the port and passes them on, or `nil` if they did not arrive.
        func read(_ count: Int, timeout: TimeInterval = 5) -> Task<Data?, Never> {
            let box = Box<Data??>(nil)
            let finished = Flag()
            queue.async {
                box.value = .some(self.terminal.read(count: count, timeout: timeout))
                finished.raise()
            }
            return Task {
                await waitUntil(timeout: timeout + 5, report: false) { finished.isRaised }
                return box.value ?? nil
            }
        }

        /// Writes `bytes` to the port after `delay` seconds.
        func send(_ bytes: Data, after delay: TimeInterval = 0) {
            queue.asyncAfter(deadline: .now() + delay) {
                try? self.terminal.write(bytes)
            }
        }

        func hangUp() {
            queue.async {
                self.terminal.close()
            }
        }

        func shutDown() {
            terminal.close()
        }
    }

    @available(macOS 10.15, *)
    final class PortAndChannelTests: XCTestCase {
        private func makeStack(
            defaultTimeout: TimeInterval = 5,
            gap: TimeInterval = 0.1
        ) async throws -> (device: FarEnd, port: PosixSerialPort, channel: SerialChannel, recorder: EventRecorder) {
            let device = try FarEnd()
            let port = PosixSerialPort(path: device.terminal.devicePath)
            let channel = SerialChannel(
                stream: port,
                configuration: SerialChannel.Configuration(defaultTimeout: defaultTimeout, postTimeoutGap: gap)
            )
            let recorder = await EventRecorder.attach(to: channel)
            return (device, port, channel, recorder)
        }

        func testARequestReachesTheDeviceByteForByteAndItsReplyComesBackRaw() async throws {
            let (device, port, channel, recorder) = try await makeStack()
            // The port is open before the device writes.
            try await channel.open()
            // Bytes a line discipline would mangle if the port left it cooked.
            let frame = Data([0x01, 0x0D, 0x0A, 0x00, 0x11, 0x13, 0x7F, 0x80, 0xFE])
            let reply = Data([0x0A, 0x0D, 0x00, 0x13, 0x81, 0xFE])
            let received = device.read(frame.count)

            let pending = Task { try await channel.request(SerialExchange(id: id(1), frame: frame, reply: .exactly(6))) }
            let seen = await received.value
            device.send(reply)
            let answer = try await pending.value

            XCTAssertEqual(seen, frame)
            XCTAssertEqual(answer, reply)
            await recorder.expectTagsWithoutRaw([.opened, .sent(1), .answered(1)])
            XCTAssertEqual(recorder.bytes(of: .sent(1)), frame)
            XCTAssertEqual(recorder.bytes(of: .answered(1)), reply)
            let isOpen = await channel.isOpen
            XCTAssertTrue(isOpen)
            XCTAssertTrue(port.isOpen)
            await channel.close()
            XCTAssertFalse(port.isOpen)
            device.shutDown()
            recorder.stop()
        }

        func testAReplyThatArrivesInTwoPartsIsAnsweredOnceWhenItIsComplete() async throws {
            let (device, _, channel, recorder) = try await makeStack()
            try await channel.open()
            let received = device.read(1)

            let pending = Task { try await channel.request(exchange(1, "Q", reply: .exactly(4))) }
            _ = await received.value
            device.send(ascii("AB"))
            device.send(ascii("CD"), after: 0.1)
            let answer = try await pending.value
            await settle(0.2)

            XCTAssertEqual(answer, ascii("ABCD"))
            await recorder.expectTagsWithoutRaw([.opened, .sent(1), .answered(1)])
            XCTAssertGreaterThanOrEqual(
                (recorder.firstEvent(.answered(1)).flatMap { event -> TimeInterval? in
                    if case .answered(_, let roundTrip) = event.kind { return roundTrip } else { return nil }
                }) ?? 0,
                0.09
            )
            await channel.close()
            device.shutDown()
            recorder.stop()
        }

        func testASilentDeviceTimesTheRequestOutAndTheNextOneIsAnswered() async throws {
            let (device, _, channel, recorder) = try await makeStack(gap: 0.1)
            try await channel.open()
            let received = device.read(2)

            let first = Task { try await channel.request(exchange(1, "A", timeout: 0.3)) }
            await waitUntil { recorder.has(.sent(1)) }
            let second = Task { try await channel.request(exchange(2, "B", timeout: 5)) }
            // The device has both frames only once the pause after the timeout is over; it answers then.
            let seen = await received.value
            device.send(ascii("Z"))
            let firstError = await errorOf { try await first.value }
            let secondReply = try await second.value

            // The device read A, then B once the pause after the timeout was over.
            XCTAssertEqual(seen, ascii("AB"))
            XCTAssertEqual(firstError as? SerialChannelError, .timedOut)
            XCTAssertEqual(secondReply, ascii("Z"))
            await channel.close()
            device.shutDown()
            recorder.stop()
        }

        func testTheDeviceHangingUpFailsTheRequestAndClosesTheChannelWithRemoved() async throws {
            let (device, port, channel, recorder) = try await makeStack()
            try await channel.open()
            let pending = Task { try await channel.request(exchange(1, "Q", timeout: 5)) }
            await waitUntil { recorder.has(.sent(1)) }

            device.hangUp()
            let error = await errorOf { try await pending.value }
            await waitUntil { !port.isOpen }

            XCTAssertEqual(error as? SerialChannelError, .closed(.removed))
            let isOpen = await channel.isOpen
            XCTAssertFalse(isOpen)
            await recorder.expectTagsWithoutRaw([.opened, .sent(1), .closed(.removed)])
            await channel.close()
            device.shutDown()
            recorder.stop()
        }

        func testAPathThatCannotBeOpenedFailsTheOpenWithTheSystemsError() async throws {
            let port = PosixSerialPort(path: "/dev/serial-port-swift-does-not-exist")
            let channel = SerialChannel(stream: port)

            let error = await errorOf { try await channel.open() }

            guard case .closed(.failed(.openFailed(let path, _)))? = error as? SerialChannelError else {
                return XCTFail("Unexpected \(String(describing: error))")
            }
            XCTAssertEqual(path, "/dev/serial-port-swift-does-not-exist")
            let isOpen = await channel.isOpen
            XCTAssertFalse(isOpen)
        }
    }

#endif
