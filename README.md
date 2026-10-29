# SerialPortSwift

Talk to serial devices from Swift. Open a port, send and receive bytes, ask a device a question and wait for its answer, find the serial ports on a Mac and notice when one is plugged in.

It is a Swift successor to [ORSSerialPort](https://github.com/armadsen/ORSSerialPort). It runs on macOS 10.11 and later and on Linux, and it needs Swift 5.1 or later.

- [Installation](#installation)
- [Quick start](#quick-start)
- [Finding ports on a Mac](#finding-ports-on-a-mac)
- [Asking a device and waiting for the answer](#asking-a-device-and-waiting-for-the-answer)
- [Port settings](#port-settings)
- [Watching the traffic](#watching-the-traffic)
- [Testing without hardware](#testing-without-hardware)
- [Errors and close reasons](#errors-and-close-reasons)
- [Linux notes](#linux-notes)
- [Contributing](#contributing), [Acknowledgements](#acknowledgements) and [License](#license)

## Installation

SerialPortSwift is installed with the Swift Package Manager. Add it to the `dependencies` of your `Package.swift`, and add the library to the target that talks to the device:

```swift
// swift-tools-version:5.1
import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [.macOS(.v10_11)],
    dependencies: [
        .package(url: "https://github.com/omarzl/SerialPortSwift.git", from: "0.1.0")
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                .product(name: "SerialPortSwift", package: "SerialPortSwift")
            ]
        ),
        .testTarget(
            name: "MyAppTests",
            dependencies: [
                "MyApp",
                .product(name: "SerialPortSwiftSimulation", package: "SerialPortSwift")
            ]
        )
    ]
)
```

The package has two libraries:

| Library | What it is for |
| --- | --- |
| `SerialPortSwift` | Everything you need in your app: the serial port, port discovery and the request queue. |
| `SerialPortSwiftSimulation` | Fake devices for your tests and simulators. Your shipping app does not need it. See [Testing without hardware](#testing-without-hardware). |

In Xcode, choose **File › Add Packages…**, paste `https://github.com/omarzl/SerialPortSwift.git`, and add the `SerialPortSwift` library to your target.

Then import it:

```swift
import SerialPortSwift
```

## Quick start

Open a port by its path, listen for bytes, write some bytes, and close the port.

```swift
import Foundation
import SerialPortSwift

final class Listener: SerialByteStreamDelegate {
    func streamDidOpen(_ stream: SerialByteStream) {
        print("Opened \(stream.name)")
    }

    func stream(_ stream: SerialByteStream, didReceive bytes: Data) {
        let text = String(decoding: bytes, as: UTF8.self)
        print("Received: \(text)")
    }

    func streamDidClose(_ stream: SerialByteStream, reason: SerialCloseReason) {
        print("Closed: \(reason)")
    }
}

let listener = Listener()

let configuration = SerialPortConfiguration(baudRate: 115200)
let port = PosixSerialPort(path: "/dev/cu.usbserial-1420", configuration: configuration)
port.delegate = listener

port.open()
port.write(Data("hello\r\n".utf8))

// Keep the program running for a few seconds while bytes arrive.
RunLoop.main.run(until: Date(timeIntervalSinceNow: 5))

port.close()
```

`PosixSerialPort` is a `SerialByteStream`: a two-way stream of bytes. The fake devices in [Testing without hardware](#testing-without-hardware) are streams too, so code written for a `SerialByteStream` works with a real port and with a fake one.

Things to know:

- **`open()` does not throw.** If the port cannot be opened, your delegate hears `streamDidClose` with the reason, for example `.failed(.openFailed(path:code:))`. See [Errors and close reasons](#errors-and-close-reasons).
- **The port keeps its delegate weakly.** Keep your own reference to the delegate (a property or a variable), or it will be released and you will hear nothing. The same is true for the queue's delegate and observers, and for the port monitor's delegate.
- **Received bytes arrive on a background queue, not on the main thread.** If you update the screen, hop to the main queue first with `DispatchQueue.main.async`.
- **A chunk is not a message.** A device that sends `"21.5\r\n"` may reach you as `"21."` and then `"5\r\n"`. If you need whole replies, use the request queue described [below](#asking-a-device-and-waiting-for-the-answer).
- **`write` does not wait.** It queues the bytes, keeps their order and returns. Writing to a closed port does nothing.
- On a Mac, the port to open is the *callout* device, `/dev/cu.*`. [`SerialPortMonitor`](#finding-ports-on-a-mac) gives you that path for every port. On Linux it is something like `/dev/ttyUSB0`.

## Finding ports on a Mac

`SerialPortMonitor` lists the serial ports and tells you when one is plugged in or removed, and when the Mac goes to sleep and wakes up. Create it and use it on the main thread. Its callbacks arrive on the main thread.

```swift
import SerialPortSwift

final class PortWatcher: SerialPortMonitorDelegate {
    private let monitor = SerialPortMonitor()
    private var port: PosixSerialPort?

    func start() {
        self.monitor.delegate = self
        for descriptor in self.monitor.availablePorts {
            print("\(descriptor.name) is at \(descriptor.calloutPath)")
        }
    }

    func open(_ descriptor: SerialPortDescriptor) {
        let configuration = SerialPortConfiguration(baudRate: 9600)
        let port = PosixSerialPort(descriptor: descriptor, configuration: configuration)
        self.port = port
        port.open()
    }

    func serialPortMonitor(_ monitor: SerialPortMonitor, didConnect ports: [SerialPortDescriptor]) {
        for descriptor in ports {
            print("Plugged in: \(descriptor.name)")
        }
    }

    func serialPortMonitor(_ monitor: SerialPortMonitor, didDisconnect ports: [SerialPortDescriptor]) {
        for descriptor in ports {
            print("Removed: \(descriptor.name)")
        }
    }

    func serialPortMonitorSystemWillSleep(_ monitor: SerialPortMonitor) {
        self.port?.close()
    }

    func serialPortMonitorSystemDidWake(_ monitor: SerialPortMonitor) {
        self.port?.open()
    }
}
```

- `availablePorts` lists the ports present right now, sorted by name.
- A `SerialPortDescriptor` has a `name` (such as `usbserial-1420`), a `calloutPath` (`/dev/cu.usbserial-1420`, the one to open) and, when the system has one, a `dialinPath`.
- `didConnect` and `didDisconnect` are not called for ports that were already there when you created the monitor. Read `availablePorts` for those.
- When the Mac is about to sleep, close your open ports. Open them again when it wakes up.
- Only macOS has the monitor. See [Linux notes](#linux-notes).

## Asking a device and waiting for the answer

Many devices work like this: you send a command, and the device sends one answer. `SerialRequestQueue` does the waiting for you. You hand it requests. It sends them one at a time, waits for each answer (or a timeout), and tells your delegate what happened.

The queue works on top of a port. You open and close the queue, and the queue opens and closes the port. Do not set your own delegate on the port.

```swift
import Foundation
import SerialPortSwift

final class Thermometer: SerialTransportDelegate {
    private let port: PosixSerialPort
    private let queue: SerialRequestQueue

    init(path: String) {
        self.port = PosixSerialPort(path: path, configuration: SerialPortConfiguration(baudRate: 9600))
        self.queue = SerialRequestQueue(stream: self.port)
        self.queue.delegate = self
    }

    func start() {
        self.queue.open()

        // Ask for the temperature. The device answers with five bytes, like "21.5\n".
        let question = SerialExchange(
            id: SerialExchangeID(number: 1),
            frame: Data("T\r".utf8),
            reply: .exactly(5)
        )
        self.queue.send(question)
    }

    func stop() {
        self.queue.close()
    }

    // These four methods are called on the main queue.

    func transportDidOpen(_ transport: SerialTransport) {
        print("Connected to \(transport.name)")
    }

    func transportDidClose(_ transport: SerialTransport, reason: SerialCloseReason) {
        print("Closed: \(reason)")
    }

    func transport(_ transport: SerialTransport, didAnswer exchange: SerialExchange, with reply: Data) {
        let text = String(decoding: reply, as: UTF8.self)
        print("Request \(exchange.id.number) was answered: \(text)")
    }

    func transport(_ transport: SerialTransport, didTimeOut exchange: SerialExchange) {
        print("Request \(exchange.id.number) got no answer")
    }
}
```

A `SerialExchange` has four parts:

- `id`: a number you pick. It comes back with the answer, so you can tell which request it was for.
- `frame`: the bytes to send.
- `reply`: what the answer looks like. `.exactly(5)` means "five bytes (or characters, see below)". `.anything` means "the first byte that arrives", which is enough to find out that a device is alive.
- `timeout`: how many seconds to wait for the answer. Leave it out to use the queue's default, which is 1 second.

What to expect:

- **The delegate is called on the main queue.** Your program needs a running main queue for that, as every app has. A command-line tool must keep it alive, for example with `dispatchMain()` or `RunLoop.main.run()`, or give the queue another queue to deliver on (see the table below).
- **Open the queue first.** Requests sent to a queue that is not open are ignored. If the port cannot be opened, you hear `transportDidClose` with the reason.
- **Every request ends with exactly one call:** `didAnswer` or `didTimeOut`. If the queue closes first, the requests that were not finished are dropped and you only hear `transportDidClose`.
- **The queue is also the port's delegate.** It keeps its own delegate weakly, like the port does. Keep a reference to yours.

### Several requests, one at a time

You can send many requests without waiting. The queue keeps them in order and sends only one at a time. The next one is written when the previous one is answered or has timed out.

```swift
let queue = SerialRequestQueue(stream: port)
queue.open()

queue.send(SerialExchange(id: SerialExchangeID(number: 1), frame: Data("A\r".utf8), reply: .exactly(2)))
queue.send(SerialExchange(id: SerialExchangeID(number: 2), frame: Data("B\r".utf8), reply: .exactly(2)))

// Bytes the device does not answer. They wait for their turn, too,
// so the device sees everything in the order you sent it.
queue.sendWithoutReply(Data("LED ON\r".utf8))

// Changed your mind? Drop the requests that have not been sent yet.
// The one already on the wire is still answered or timed out.
// Writes without a reply stay queued. You get back the ids that were dropped.
let dropped: [SerialExchangeID] = queue.cancelQueuedExchanges()

// Run something when everything sent so far is finished (on the same queue as your delegate).
queue.whenIdle {
    print("Nothing left to wait for")
}
```

### Timeouts

The timer starts when the queue hands the request to the port. If no answer comes in time, the delegate gets `didTimeOut` and the queue moves on to the next request.

A late answer can confuse the request that comes after it. So after a timeout the queue waits a moment (a tenth of a second by default) before it sends the next request, and throws away anything that arrives during that moment.

### How a reply is recognised

The queue reads the bytes that arrive after a request was sent and looks for the end of the reply. As soon as the last *n* bytes it has received match what you asked for, those bytes are the reply, exactly as they came. Bytes that arrive after the reply, or that arrive when nothing is waiting, are thrown away.

`TailScanMatcher` is the default rule, and you can give it three options:

```swift
let matcher = TailScanMatcher(
    fillerBytes: [0xFF],
    requiresASCII: true,
    lengthUnit: .characters
)
let queue = SerialRequestQueue(stream: port, matcher: matcher)
```

| Option | What it does |
| --- | --- |
| `fillerBytes` | Padding bytes some devices send (often `0xFF` or `0x00`). They are not counted. Padding before or after the reply is not part of what you get. Padding inside the reply stays. |
| `requiresASCII` | For devices that talk plain text. A byte above `0x7F` cannot be part of a reply. Observers are told about it, which helps to spot noise or a wrong baud rate. |
| `lengthUnit` | What `.exactly(n)` counts. `.bytes` is the default. With `.characters` it counts characters the way Swift's `String` does, so `"\r\n"` counts as one. `"OK\r\n"` is four bytes but three characters. For replies that end in `"\r\n"`, use `.bytes`: with `.characters` the reply is found as soon as the `"\r"` arrives. |

If your replies follow another rule, write your own matcher. The queue offers it the last byte received, then the last two bytes, and so on. The first one you accept is the reply. For example, a reply that is four bytes long and starts with `0x02`:

```swift
struct FramedMatcher: ReplyMatcher {
    func verdict(on candidate: Data, expecting shape: ReplyShape) -> ReplyVerdict {
        if candidate.count == 4 && candidate.first == 0x02 {
            return .accepted
        }
        return .rejected
    }
}

let queue = SerialRequestQueue(stream: port, matcher: FramedMatcher())
// Use .anything as the reply shape: this matcher ignores it.
```

### Queue settings

Pass a `SerialRequestQueue.Configuration` to change the defaults:

```swift
let configuration = SerialRequestQueue.Configuration(
    defaultTimeout: 2,
    maximumReplyLength: 256,
    postTimeoutGap: 0.2,
    deliveryQueue: DispatchQueue(label: "my.replies")
)
let queue = SerialRequestQueue(stream: port, configuration: configuration)
```

| Setting | Default | Meaning |
| --- | --- | --- |
| `defaultTimeout` | 1 second | How long to wait for a request that has no `timeout` of its own. |
| `maximumReplyLength` | 64 | How many of the latest bytes the queue keeps while it waits for a reply. An `.exactly(n)` reply always gets room for its *n* bytes, so this only matters for a matcher of your own that needs longer replies. |
| `postTimeoutGap` | 0.1 seconds | The pause after a timeout during which late bytes are thrown away. `0` for no pause. |
| `deliveryQueue` | the main queue | Where your delegate is called. |

Your code can also talk to the `SerialTransport` protocol instead of the `SerialRequestQueue` class. The queue conforms to it, so you can swap in another implementation later.

## Port settings

`SerialPortConfiguration` says how the line is set up when the port opens. Every field has a default, so you only name the ones you change.

```swift
var configuration = SerialPortConfiguration()
configuration.baudRate = 115200
configuration.parity = .even
configuration.stopBits = .two
configuration.flowControl = [.rtsCts]
configuration.linesAfterOpen = SerialPortConfiguration.LineLevels(dtr: true, rts: false)
configuration.exclusiveAccess = false

let port = PosixSerialPort(path: "/dev/cu.usbserial-1420", configuration: configuration)
```

| Field | Default | Meaning |
| --- | --- | --- |
| `baudRate` | `9600` | The speed in bits per second. |
| `dataBits` | `.eight` | `.five`, `.six`, `.seven` or `.eight`. |
| `parity` | `.none` | `.none`, `.odd` or `.even`. |
| `stopBits` | `.one` | `.one` or `.two`. |
| `flowControl` | none (`[]`) | Any of `.rtsCts`, `.dtrDsr` and `.dcdOutput`. The last two only work on macOS. |
| `echo` | `false` | Whether received characters are echoed back to the sender. |
| `linesAfterOpen` | DTR low, RTS low | The levels DTR and RTS are driven to right after the port opens. Use `nil` to leave them as the driver set them. |
| `exclusiveAccess` | `true` | While the port is open, other openers are refused (they get `exclusiveAccessDenied`). Set `false` to let other programs open it too. |

The port is always in raw mode: no line editing, no translation of characters. What you write is what goes out, and what the device sends is what you get.

If the system cannot do the baud rate, opening fails with `unsupportedBaudRate`. A Mac also accepts unusual rates when the hardware can do them. Linux accepts the standard rates, up to 4000000.

### Modem lines

You can read the modem lines of an open port and drive DTR and RTS yourself:

```swift
switch port.readModemLines() {
case .success(let lines):
    print(lines.contains(.cts) ? "CTS is on" : "CTS is off")
case .failure(let error):
    print("Cannot read the lines: \(error)")
}

// Raise DTR. nil leaves RTS as it is.
let result = port.setModemLines(dtr: true, rts: nil)
```

`ModemLines` has `.dtr` and `.rts` (outputs you can set) and `.cts`, `.dsr`, `.dcd` and `.ri` (inputs you can read). Both calls answer the lines as they are after the call. They fail with `modemLinesUnavailable` when the port is closed or the device has no such lines. If DTR and RTS could not be set while opening, the port still opens, and `port.modemLinesError` tells you why.

## Watching the traffic

A `SerialQueueObserver` hears everything that happens on a `SerialRequestQueue`. It is good for logs, for a console that shows the traffic and for finding out why a device does not answer.

```swift
import Foundation
import SerialPortSwift

final class TrafficLog: SerialQueueObserver {
    func requestQueue(_ queue: SerialRequestQueue, didLog event: SerialQueueEvent) {
        let hex = (event.bytes ?? Data()).map { String(format: "%02X", $0) }.joined(separator: " ")
        switch event.kind {
        case .sent:
            print("-> \(hex)")
        case .raw:
            print("<- \(hex)")
        case .answered(let id, let roundTrip):
            print("Request \(id.number) answered in \(roundTrip) seconds")
        case .timedOut(let id):
            print("Request \(id.number) timed out")
        default:
            print("\(event.kind)")
        }
    }
}

let log = TrafficLog()
queue.addObserver(log)
// Later: queue.removeObserver(log)
```

- The queue holds observers weakly. Keep a reference to yours.
- Observers are called one event after another, on a background queue, not on the main thread. Keep your code quick. If you do something slow, such as writing a file, hand it to another queue.

Each event has a `date`, a `kind` and sometimes `bytes`:

| Kind | What it means | `bytes` |
| --- | --- | --- |
| `.opened` | The queue is open. | none |
| `.closed(reason)` | The queue closed, and why. | none |
| `.sent(id)` | Bytes were written to the device. `id` is the request, or `nil` for a write without a reply. | what was written |
| `.raw` | Bytes arrived, exactly as the port delivered them, before the queue decides what they are. | what arrived |
| `.answered(id, roundTrip:)` | A request was answered. `roundTrip` is the time in seconds from the write to the last byte of the answer. | the reply |
| `.timedOut(id)` | A request got no answer in time. | the bytes that were sent |
| `.unreadableCandidate(id)` | While waiting for a request, bytes arrived that the matcher cannot read (see `requiresASCII`). | the unreadable bytes |
| `.lateBytesDropped` | Bytes arrived just after a timeout. They were thrown away. | the dropped bytes |
| `.unsolicitedBytesDropped` | Bytes arrived when no request was waiting, or after a reply. They were thrown away. | the dropped bytes |
| `.cancelled(ids)` | `cancelQueuedExchanges()` dropped these requests. | none |

### Round-trip times

`RoundTripStatistics` keeps the most recent round-trip times for any key you choose (a device, a command) and gives you the median and the 99th percentile. Feed it from an observer:

```swift
import Foundation
import SerialPortSwift

final class Timings: SerialQueueObserver {
    private let lock = NSLock()
    private var statistics = RoundTripStatistics<String>(windowSize: 200)

    func requestQueue(_ queue: SerialRequestQueue, didLog event: SerialQueueEvent) {
        guard case .answered(_, let roundTrip) = event.kind else {
            return
        }
        self.lock.lock()
        self.statistics.record(roundTrip, for: "temperature")
        self.lock.unlock()
    }

    func report() {
        self.lock.lock()
        let summary = self.statistics.summary(for: "temperature")
        self.lock.unlock()
        if let summary = summary {
            print("Median \(summary.median) s, 99th percentile \(summary.p99) s, over \(summary.count) round trips")
        }
    }
}
```

`windowSize` is how many recent round trips each key remembers (1000 by default). `summary(for:)` answers `nil` until something was recorded for that key. `RoundTripStatistics` is a plain value with no locking, so use it from one thread at a time, as the lock does above.

## Testing without hardware

The `SerialPortSwiftSimulation` library gives you stand-ins for a real device, so you can test your code on any machine and in CI. Add it to your *test* target only (see [Installation](#installation)).

```swift
import SerialPortSwiftSimulation
```

### A simulated device

Write a small type that answers each frame, and put it behind a `SimulatedByteStream`. Use the stream wherever you would use a port.

```swift
import Foundation
import SerialPortSwift
import SerialPortSwiftSimulation

final class FakeThermometer: SerialDeviceSimulator {
    func reply(to frame: Data) -> Data? {
        if frame == Data("T\r".utf8) {
            return Data("21.5\n".utf8)
        }
        return nil   // The device says nothing.
    }
}

let stream = SimulatedByteStream(device: FakeThermometer(), replyLatency: 0.02)
let queue = SerialRequestQueue(stream: stream)
```

Each `write` is one frame, and the answer comes back after `replyLatency` seconds. You can rehearse a bad wire:

```swift
stream.dropNextReply()        // The next answer never comes: the request times out.
stream.fillerByteCount = 2    // Put two padding bytes in front of every answer...
stream.fillerByte = 0xFF      // ...and choose what they are (0xFF by default).
stream.replyLatency = 0.5     // Make the device slow.
stream.simulateRemoval()      // Unplug the device: the stream closes with .removed.
```

Opening the stream again plugs the device back in. To test padding, tell the matcher about it: `TailScanMatcher(fillerBytes: [0xFF])`.

### A recorded conversation

`ReplayByteStream` plays a script. Each write uses up the next step, and the step says what the device answers and when. This is good for traffic you recorded from a real device, with its timing.

```swift
let stream = ReplayByteStream(script: [
    // The first write should be "T\r". The device answers 20 ms later.
    .reply(to: Data("T\r".utf8), with: [ReplayChunk(Data("21.5\n".utf8), at: 0.02)]),
    // The second write gets no answer.
    .silence()
])
let queue = SerialRequestQueue(stream: stream)

// The device can also speak or hang up on its own:
stream.receive(Data("BOOT\r\n".utf8), after: 0.5)
stream.end(.removed, after: 1)
```

After the test, check what your code wrote:

```swift
for write in stream.writes {
    print(write.bytes, write.matchedExpectation)   // false if it was not the bytes the step expected
}
print(stream.remainingSteps)                        // steps nobody used
```

To test a port that fails to open, use `ReplayByteStream(openFailure: .openFailed(path: "/dev/missing", code: 2))`.

### A real port on a fake device

`PseudoTerminal` is a pair of connected terminals. A `PosixSerialPort` opens one end by path, and your test plays the device on the other end. This tests the real port code, with no hardware. It works on macOS and Linux.

```swift
import Foundation
import SerialPortSwift
import SerialPortSwiftSimulation

func pingTheFakeDevice() throws {
    let terminal = try PseudoTerminal()
    let port = PosixSerialPort(path: terminal.devicePath)
    port.open()

    port.write(Data("PING\r".utf8))
    let received = terminal.read(count: 5, timeout: 1)   // Data?, nil if it did not all arrive
    print(received.map { String(decoding: $0, as: UTF8.self) } ?? "nothing")

    try terminal.write(Data("PONG\r".utf8))              // The "device" answers.

    terminal.close()                                     // Hang up: the port closes with .removed.
}
```

- `terminal.read(timeout:)` returns everything that arrives until the line is quiet for `timeout` seconds.
- A pseudo-terminal has no modem lines, so `port.modemLinesError` is set. The port works anyway.

## Errors and close reasons

Whenever a port or a queue closes, you are told why with a `SerialCloseReason`:

| Reason | What happened |
| --- | --- |
| `.requested` | You called `close()`. |
| `.removed` | The device went away. It was unplugged, or the other end hung up. |
| `.failed(error)` | The port could not open, or it failed while open. `error` is a `SerialStreamError`. |

A `SerialStreamError` says what went wrong. Where it has a `code`, that is the system's `errno` (for example 2 is "no such file" and 13 is "permission denied").

| Error | Meaning |
| --- | --- |
| `.openFailed(path:code:)` | The device could not be opened: wrong path, no permission, or it is not there. |
| `.exclusiveAccessDenied(path:)` | Another program (or another port in your program) already has the device. |
| `.configurationFailed(code:)` | The line settings could not be read or applied. |
| `.unsupportedBaudRate(_)` | The system cannot do this speed on this device. |
| `.modemLinesUnavailable(code:)` | The modem lines (DTR, RTS and the others) could not be read or set. |
| `.readFailed(code:)` | Reading from the device failed. The port closes. |
| `.writeFailed(code:)` | Writing to the device failed. The port closes. |
| `.system(domain:code:description:)` | An error from another layer, kept with its domain, code and description. The ports in this package do not produce it. |

## Linux notes

- Open a port by its path, for example `/dev/ttyUSB0` or `/dev/ttyACM0`. The port is named after the last part of the path (`ttyUSB0`).
- There is no port discovery on Linux. `SerialPortMonitor` is only for macOS, so list the devices yourself (for example from `/dev`) and pass the path to `PosixSerialPort`.
- Your user needs permission to open the device. On many distributions that means being in the group that owns it, often `dialout`.
- Linux supports the standard baud rates. `.dtrDsr` and `.dcdOutput` flow control are ignored.
- If you work on the package itself with Swift 5.1 to 5.3, ask for test discovery:

  ```bash
  swift test --enable-test-discovery
  ```

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first: it explains the limits the code must respect and how to build and test it.

## Acknowledgements

SerialPortSwift follows the behaviour of [ORSSerialPort](https://github.com/armadsen/ORSSerialPort). Thank you to its author and contributors. See [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).

## License

SerialPortSwift is released under the MIT License. See [LICENSE](LICENSE).
