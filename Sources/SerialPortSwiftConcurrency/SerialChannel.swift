//
//  SerialChannel.swift
//  SerialPortSwiftConcurrency
//
//  The request/response channel of `SerialRequestQueue`, written for Swift concurrency: an actor whose
//  callers `await` their reply. A second engine, not a wrapper: it shares the library's streams and its
//  reply rule (`ReplyMatcher`), and keeps its own state the way an actor does.
//
//  No checked or unsafe continuations anywhere in this module. A stream reports through its delegate on
//  its own queue; those reports enter the actor through an `AsyncStream`, the one bridge between the two
//  worlds.
//

#if compiler(>=5.7) && canImport(_Concurrency)

    import Foundation
    import SerialPortSwift

    /// Why a request did not get its reply.
    @available(macOS 10.15, *)
    public enum SerialChannelError: Error, Equatable, Sendable {
        /// The channel was not open when the request was made.
        case notOpen
        /// The reply did not arrive in time.
        case timedOut
        /// The channel closed before the reply arrived — or, from `open()`, instead of opening.
        case closed(SerialCloseReason)
    }

    /// A request/response channel to a device, as an actor: one exchange on the wire at a time, the
    /// rest waiting their turn in the order they reached the actor.
    ///
    /// It behaves as ``SerialRequestQueue`` does, written with `async`/`await`:
    ///
    /// - **Order.** Requests and writes without a reply share one queue. A write without a reply goes
    ///   out as soon as its turn comes; a request goes out and holds the wire until its reply or its
    ///   timeout.
    /// - **Replies.** Bytes received while a request is on the wire are kept in a buffer of at most
    ///   ``Configuration/maximumReplyLength`` bytes (at least *n* for `.exactly(n)`; oldest first out)
    ///   and offered to the ``ReplyMatcher`` after every byte. The first reply it finds is returned raw.
    ///   Bytes left in the same chunk after the reply, and bytes that arrive with nothing on the wire,
    ///   are dropped.
    /// - **Timeouts.** A request's timer starts when its frame is handed to the stream. When it runs
    ///   out, the request throws ``SerialChannelError/timedOut`` and the channel pauses for
    ///   ``postTimeoutGap``; bytes that arrive in that pause are dropped, never credited to the next
    ///   request. Timers are `Task.sleep`, so a busy main thread cannot stretch them.
    /// - **Cancellation.** Cancelling the task of a request that is still waiting its turn takes it out
    ///   of the queue, and the request throws `CancellationError`. Once `cancel()` has returned, such a
    ///   request is not written, even if the exchange ahead of it is answered at that moment. A request
    ///   already on the wire is left to its reply or its timeout — the device answers it either way — and
    ///   returns or throws as usual.
    /// - **Closing.** ``close()`` and a close the stream reports on its own (the device removed, a
    ///   failure) end every request still waiting or on the wire with
    ///   ``SerialChannelError/closed(_:)``.
    ///
    /// **What differs from the queue.**
    ///
    /// - A request made while the channel is still opening throws ``SerialChannelError/notOpen``; the
    ///   queue keeps it until the stream has opened.
    /// - Bytes the stream delivers while the channel is opening produce no events; the queue publishes
    ///   them as raw and drops them as unsolicited.
    /// - There is no bulk cancel like ``SerialRequestQueue/cancelQueuedExchanges()``: cancel the tasks of
    ///   the requests.
    ///
    /// **The stream.** It becomes the channel's: the channel is its delegate, and it must be opened and
    /// closed only through the channel, never by calling `open()` or `close()` on the stream itself. The
    /// channel ends its own session before it asks the stream to close, so a close the stream reports as
    /// ``SerialCloseReason/requested`` is taken for the echo of that call, whenever it arrives, and
    /// ignored. Give the channel a stream that is not open yet; opening it is ``open()``'s job.
    ///
    /// ``open()`` and ``close()`` call the stream's own `open()` and `close()` from the actor. A stream
    /// that blocks there — a port that drains its output before it closes — holds the channel for that
    /// long: nothing else on the channel makes progress meanwhile.
    @available(macOS 10.15, *)
    public actor SerialChannel {
        public struct Configuration: Sendable {
            /// The timeout of a request that does not carry its own.
            public var defaultTimeout: TimeInterval
            /// The most bytes kept while waiting for a reply (at least *n* for `.exactly(n)`).
            public var maximumReplyLength: Int
            /// The pause after a timeout during which late bytes are dropped. `0` for none.
            public var postTimeoutGap: TimeInterval

            public init(defaultTimeout: TimeInterval = 1, maximumReplyLength: Int = 64, postTimeoutGap: TimeInterval = 0.1) {
                self.defaultTimeout = defaultTimeout
                self.maximumReplyLength = maximumReplyLength
                self.postTimeoutGap = postTimeoutGap
            }
        }

        /// The stream's name, for logs and people.
        public nonisolated let name: String

        /// The configuration the channel was made with; read the timeout of a request that carries none
        /// as `configuration.defaultTimeout`. The pause after a timeout can change while the channel
        /// runs, and ``postTimeoutGap`` is its current value.
        public nonisolated let configuration: Configuration

        // MARK: State

        private enum Connection {
            case closed
            case opening
            case open
        }

        private enum Work {
            case write(Data)
            case exchange(SerialExchange)
        }

        /// A request or a write waiting its turn. `outcome` is how the actor tells its caller what became
        /// of it; `number` names it for a cancellation, and `cancellation` is raised, at the moment the
        /// caller's task is cancelled, before the actor has heard of it.
        private struct Queued {
            let number: Int
            let work: Work
            let outcome: AsyncStream<Outcome>.Continuation
            let cancellation: CancelFlag
        }

        /// The exchange whose frame was written and whose reply is awaited. `token` names its timer.
        /// `mark` is how many reports the stream had posted when the frame was written: a chunk numbered
        /// at most `mark` was posted before the frame and cannot be its reply.
        private struct OnTheWire {
            let exchange: SerialExchange
            let writtenAt: UInt64
            let mark: Int
            let token: Int
            let timer: Task<Void, Never>
            let outcome: AsyncStream<Outcome>.Continuation
        }

        private struct IdleWaiter {
            let id: Int
            let continuation: AsyncStream<Void>.Continuation
        }

        private let stream: SerialByteStream
        private let matcher: ReplyMatcher
        private let bridge: StreamBridge

        private var connection = Connection.closed
        private var isPumpingReports = false
        /// The session the channel is in; the bridge holds the same number. A report the stream made for
        /// an earlier session carries an earlier number and is dropped.
        private var generation = 0
        private var queued: [Queued] = []
        private var onTheWire: OnTheWire?
        private var replyBuffer = Data()
        private var gap: TimeInterval
        private var inGap = false
        private var gapTimer: Task<Void, Never>?
        private var gapToken = 0
        /// How many reports the stream had posted when the last pause ended: a chunk numbered at most this
        /// was posted during the pause, however late the actor hears of it, and is late.
        private var gapMark = 0
        private var timeoutToken = 0
        private var nextTicket = 0
        private var nextExchange = 0
        private var openWaiters: [AsyncStream<OpenOutcome>.Continuation] = []
        private var idleWaiters: [IdleWaiter] = []
        private var nextIdleWaiter = 0
        private let eventHub = EventHub()

        public init(stream: SerialByteStream, matcher: ReplyMatcher = TailScanMatcher(), configuration: Configuration = Configuration()) {
            self.name = stream.name
            self.stream = stream
            self.matcher = matcher
            self.configuration = configuration
            self.gap = configuration.postTimeoutGap
            let bridge = StreamBridge()
            self.bridge = bridge
            stream.delegate = bridge
        }

        public var isOpen: Bool {
            return connection == .open
        }

        /// The pause after a timeout. Starts at ``Configuration/postTimeoutGap``; a change applies from
        /// the next timeout.
        public var postTimeoutGap: TimeInterval {
            return gap
        }

        public func setPostTimeoutGap(_ gap: TimeInterval) {
            self.gap = gap
        }

        // MARK: Opening and closing

        /// Opens the stream and returns once it is open. Throws ``SerialChannelError/closed(_:)`` with
        /// the stream's reason when it cannot open. Opening an open channel does nothing.
        ///
        /// A stream that opens asynchronously is waited for. A task cancelled meanwhile still waits: it is
        /// ``close()`` that ends an open that never completes, with `.closed(.requested)`.
        ///
        /// The stream's own `open()` is called from the actor, so a stream that blocks in it holds the
        /// channel until it returns.
        public func open() async throws {
            let outcomes: AsyncStream<OpenOutcome>
            switch connection {
            case .open:
                return
            case .opening:
                outcomes = addOpenWaiter()
            case .closed:
                startPumpingReports()
                generation = bridge.advance()
                connection = .opening
                outcomes = addOpenWaiter()
                // A stream may report from inside this call; the report waits for this method to suspend.
                stream.open()
            }
            switch await firstValue(of: outcomes, orElse: .closed(.requested)).value {
            case .opened:
                return
            case .closed(let reason):
                throw SerialChannelError.closed(reason)
            }
        }

        /// Closes the stream. Every request still waiting or on the wire throws
        /// ``SerialChannelError/closed(_:)`` with `.requested`. Closing a closed channel does nothing.
        ///
        /// The stream's own `close()` is called from the actor, so a stream that blocks in it — a port that
        /// drains its output first — holds the channel until it returns.
        public func close() async {
            guard connection != .closed else {
                return
            }
            finishSession(.requested)
            // The channel is closed whatever the stream reports for this, and a stream that is not open yet
            // reports nothing. If it opens after all, `streamDidOpen` closes it again.
            stream.close()
        }

        // MARK: Requests

        /// Writes the exchange's frame when its turn comes and returns its reply, raw, exactly as
        /// received. Throws ``SerialChannelError/notOpen``, ``SerialChannelError/timedOut``,
        /// ``SerialChannelError/closed(_:)``, or `CancellationError` (see the type's notes).
        public func request(_ exchange: SerialExchange) async throws -> Data {
            try Task.checkCancellation()
            guard connection == .open else {
                throw SerialChannelError.notOpen
            }
            switch await outcome(of: enqueue(.exchange(exchange))) {
            case .answered(let reply):
                return reply
            case .timedOut:
                throw SerialChannelError.timedOut
            case .closed(let reason):
                throw SerialChannelError.closed(reason)
            case .cancelled:
                throw CancellationError()
            case .written:
                // An exchange is answered, not written.
                assertionFailure("A request cannot end as a write")
                throw SerialChannelError.closed(.requested)
            }
        }

        /// A request whose id the channel picks. The ids count from 1 on each channel, and the channel does
        /// not look at the ids you give to `request(_:)`, so on one channel the two can be the same: the
        /// events then name two exchanges by one id. Use one form on a channel, or number your own
        /// exchanges apart from the small numbers.
        public func request(_ frame: Data, reply: ReplyShape, timeout: TimeInterval? = nil) async throws -> Data {
            nextExchange += 1
            let exchange = SerialExchange(id: SerialExchangeID(number: nextExchange), frame: frame, reply: reply, timeout: timeout)
            return try await request(exchange)
        }

        /// Writes `frame` when its turn comes, without waiting for a reply, and returns once it has been
        /// handed to the stream. Throws ``SerialChannelError/notOpen``, ``SerialChannelError/closed(_:)``
        /// or `CancellationError` (cancelled before its turn).
        public func send(_ frame: Data) async throws {
            try Task.checkCancellation()
            guard connection == .open else {
                throw SerialChannelError.notOpen
            }
            switch await outcome(of: enqueue(.write(frame))) {
            case .written:
                return
            case .closed(let reason):
                throw SerialChannelError.closed(reason)
            case .cancelled:
                throw CancellationError()
            case .answered, .timedOut:
                // A write has no reply to wait for.
                assertionFailure("A write cannot be answered or time out")
                throw SerialChannelError.closed(.requested)
            }
        }

        /// Returns once nothing is queued and nothing is on the wire — at once if that is already so,
        /// or if the channel is closed. It also returns at once when its task is cancelled, whether or not
        /// the channel is idle: a cancelled task does not wait.
        public func waitUntilIdle() async {
            if connection == .closed || isIdle {
                return
            }
            nextIdleWaiter += 1
            let id = nextIdleWaiter
            let (waiting, continuation) = makeMailbox(Void.self)
            let owner = WeakChannel(self)
            continuation.onTermination = { @Sendable termination in
                // A waiter whose task was cancelled gives up; the channel need not keep it.
                guard case .cancelled = termination, let channel = owner.object else {
                    return
                }
                Task { await channel.forgetIdleWaiter(id) }
            }
            idleWaiters.append(IdleWaiter(id: id, continuation: continuation))
            for await _ in waiting {
                return
            }
        }

        /// Everything that happens on the channel from now on, in order: the same events a
        /// ``SerialRequestQueue`` gives its observers. Each call returns a stream of its own; it ends when
        /// the caller stops iterating or the channel is released.
        ///
        /// A request taken out of the queue by a cancellation is published as `.cancelled`, as
        /// ``SerialRequestQueue/cancelQueuedExchanges()`` does; a write without a reply has no id and
        /// publishes nothing.
        ///
        /// A stream buffers without limit. A consumer that stops iterating but neither cancels its task nor
        /// leaves the loop leaves its stream growing with every event until the channel is released: end
        /// a stream you no longer read.
        public func events() -> AsyncStream<SerialQueueEvent> {
            let (events, continuation) = makeMailbox(SerialQueueEvent.self)
            let id = eventHub.add(continuation)
            // The consumer stopping takes its stream out of the hub, wherever it stops: no hop to the actor,
            // and no strong reference to the hub or the channel, which a consumer must not keep alive.
            let hub = WeakEventHub(eventHub)
            continuation.onTermination = { @Sendable _ in
                hub.object?.remove(id)
            }
            return events
        }

        // MARK: For the tests

        /// How many requests and writes wait their turn.
        var queuedCount: Int {
            return queued.count
        }

        /// How many streams ``events()`` gave are still being consumed.
        var eventConsumerCount: Int {
            return eventHub.count
        }

        /// How many calls of ``waitUntilIdle()`` are waiting.
        var idleWaiterCount: Int {
            return idleWaiters.count
        }

        // MARK: Queueing

        /// Nothing queued and nothing on the wire.
        private var isIdle: Bool {
            return queued.isEmpty && onTheWire == nil
        }

        private func enqueue(_ work: Work) -> Ticket {
            nextTicket += 1
            let (outcomes, continuation) = makeMailbox(Outcome.self)
            let cancellation = CancelFlag()
            queued.append(Queued(number: nextTicket, work: work, outcome: continuation, cancellation: cancellation))
            drainQueue()
            return Ticket(number: nextTicket, outcomes: outcomes, cancellation: cancellation)
        }

        /// What became of a request or a write.
        ///
        /// The caller waits in a task of its own, one that its cancellation does not reach: a stream ends
        /// its iteration as soon as the task consuming it is cancelled, and a request on the wire is left
        /// to its reply.
        ///
        /// The cancellation handler runs on the thread that cancels, so all it does at once is raise the
        /// ticket's flag, which `drainQueue` looks at before it writes anything: when `cancel()` returns,
        /// the request will not be written. Taking it out of the queue, and waking whoever waits for the
        /// channel to be idle, needs the actor, so the handler asks it to.
        private func outcome(of ticket: Ticket) async -> Outcome {
            let number = ticket.number
            let waiter = firstValue(of: ticket.outcomes, orElse: .closed(.requested))
            let cancellation = ticket.cancellation
            let cancel: @Sendable () -> Void = { [self] in
                cancellation.raise()
                Task { await self.cancelQueued(number) }
            }
            return await withTaskCancellationHandler(operation: { await waiter.value }, onCancel: cancel)
        }

        /// Takes the request or write out of the queue if it is still waiting its turn.
        private func cancelQueued(_ number: Int) {
            guard let index = queued.firstIndex(where: { $0.number == number }) else {
                return
            }
            withdraw(queued.remove(at: index))
            if connection == .open && isIdle {
                resumeIdleWaiters()
            }
        }

        /// Ends a request or write that was cancelled before its turn: its caller throws `CancellationError`,
        /// and an exchange is published as `.cancelled`.
        private func withdraw(_ item: Queued) {
            if case .exchange(let exchange) = item.work {
                publish(.cancelled([exchange.id]))
            }
            resolve(item.outcome, .cancelled)
        }

        /// Writes what is next in line, until an exchange is on the wire or the line is empty.
        private func drainQueue() {
            while connection == .open && onTheWire == nil && !inGap && !queued.isEmpty {
                let item = queued.removeFirst()
                if item.cancellation.isRaised {
                    // Cancelled while it waited, before `cancelQueued` could take it out: it is not written.
                    withdraw(item)
                    continue
                }
                switch item.work {
                case .write(let frame):
                    stream.write(frame)
                    publish(.sent(nil), bytes: frame)
                    resolve(item.outcome, .written)
                case .exchange(let exchange):
                    replyBuffer = Data()
                    // Whatever the stream has posted by now was received before this frame went out.
                    let mark = bridge.posted
                    stream.write(exchange.frame)
                    let writtenAt = DispatchTime.now().uptimeNanoseconds
                    timeoutToken += 1
                    let token = timeoutToken
                    let deadline = writtenAt &+ nanoseconds(exchange.timeout ?? configuration.defaultTimeout)
                    let owner = WeakChannel(self)
                    let timer = startTimer(untilUptime: deadline) {
                        await owner.object?.timeoutFired(token)
                    }
                    onTheWire = OnTheWire(exchange: exchange, writtenAt: writtenAt, mark: mark, token: token, timer: timer, outcome: item.outcome)
                    publish(.sent(exchange.id), bytes: exchange.frame)
                }
            }
            if connection == .open && isIdle {
                resumeIdleWaiters()
            }
        }

        /// The timer that `token` names has run out. The token is all that ties a timer to its exchange, so a
        /// timer that is late — its exchange answered, closed or replaced — finds another token and does
        /// nothing. Not private, so that a test can fire a timer that is stale.
        func timeoutFired(_ token: Int) {
            guard let flight = onTheWire, flight.token == token, connection == .open else {
                return
            }
            publish(.timedOut(flight.exchange.id), bytes: flight.exchange.frame)
            onTheWire = nil
            replyBuffer = Data()
            resolve(flight.outcome, .timedOut)
            if gap > 0 {
                inGap = true
                gapToken += 1
                let token = gapToken
                let deadline = DispatchTime.now().uptimeNanoseconds &+ nanoseconds(gap)
                let owner = WeakChannel(self)
                gapTimer = startTimer(untilUptime: deadline) {
                    await owner.object?.gapEnded(token)
                }
                if queued.isEmpty {
                    resumeIdleWaiters()
                }
            } else {
                drainQueue()
            }
        }

        /// The pause that `token` names is over. As with `timeoutFired`, a stale token does nothing, and the
        /// function is not private for the same reason.
        func gapEnded(_ token: Int) {
            guard inGap, gapToken == token else {
                return
            }
            inGap = false
            gapTimer = nil
            // Whatever the stream has posted by now arrived during the pause, even if the actor hears of it
            // only after it.
            gapMark = bridge.posted
            drainQueue()
        }

        // MARK: Receiving

        /// `sequence` is the chunk's number among what the stream reported. The stream and the actor are two
        /// places, so a chunk can be posted before something the actor does and be heard of after it. What
        /// tells whether it came first is its number, never the moment the actor hears of it, and never a
        /// clock.
        private func process(_ chunk: Data, arrivedAt date: Date, monotonic: UInt64, sequence: Int) {
            guard connection == .open else {
                return
            }
            publish(.raw, bytes: chunk, date: date)
            if inGap || sequence <= gapMark {
                publish(.lateBytesDropped, bytes: chunk)
                return
            }
            guard let flight = onTheWire, sequence > flight.mark else {
                // Nothing is on the wire, or the chunk arrived before the frame that is: it answers nothing.
                publish(.unsolicitedBytesDropped, bytes: chunk)
                return
            }
            var limit = max(1, configuration.maximumReplyLength)
            if case .exactly(let length) = flight.exchange.reply {
                // The reply cannot be found if it does not fit in the buffer.
                limit = max(limit, length)
            }
            let bytes = Array(chunk)
            for (position, byte) in bytes.enumerated() {
                replyBuffer.append(byte)
                if replyBuffer.count > limit {
                    replyBuffer = Data(replyBuffer.suffix(limit))
                }
                let scan = matcher.scan(replyBuffer, expecting: flight.exchange.reply)
                if let unreadable = scan.unreadable {
                    publish(.unreadableCandidate(flight.exchange.id), bytes: unreadable)
                }
                guard let packet = scan.packet else {
                    continue
                }
                flight.timer.cancel()
                let elapsed = monotonic > flight.writtenAt ? monotonic - flight.writtenAt : 0
                onTheWire = nil
                replyBuffer = Data()
                publish(.answered(flight.exchange.id, roundTrip: TimeInterval(elapsed) / 1_000_000_000), bytes: packet)
                resolve(flight.outcome, .answered(packet))
                if position + 1 < bytes.count {
                    publish(.unsolicitedBytesDropped, bytes: Data(bytes[(position + 1)...]))
                }
                drainQueue()
                return
            }
        }

        // MARK: What the stream reports

        /// Starts the task that carries everything the stream reports to the actor, in order. One task for
        /// the life of the channel, started by the first `open()`: a stream reports nothing before that. It
        /// holds the channel weakly and ends when the bridge, which the channel owns, is released.
        private func startPumpingReports() {
            guard !isPumpingReports else {
                return
            }
            isPumpingReports = true
            pumpReports(bridge.reports, into: WeakChannel(self))
        }

        fileprivate func handle(_ stamped: StreamBridge.Stamped) {
            switch stamped.report {
            case .opened:
                streamDidOpen()
            case .received(let chunk, let date, let monotonic):
                if stamped.generation == generation {
                    process(chunk, arrivedAt: date, monotonic: monotonic, sequence: stamped.sequence)
                }
            case .closed(let reason):
                // The channel ends its session before it asks the stream to close, so a close reported as
                // `.requested` is the echo of that call, whenever the stream makes it: if it comes late
                // enough, it carries the number of a session that began after. Only the channel closes its
                // stream.
                if stamped.generation == generation && reason != .requested {
                    streamDidClose(reason)
                }
            }
        }

        /// An open report says the stream is open now, whichever open it answers.
        private func streamDidOpen() {
            switch connection {
            case .opening:
                connection = .open
                publish(.opened)
                resolveOpenWaiters(.opened)
            case .open:
                break
            case .closed:
                // The close overtook the open. Whatever the stream reports for this is ignored.
                generation = bridge.advance()
                stream.close()
            }
        }

        private func streamDidClose(_ reason: SerialCloseReason) {
            guard connection != .closed else {
                return
            }
            finishSession(reason)
        }

        /// Closes the channel and tells everyone who waits: the requests, the writes, an `open()`, the
        /// idle waiters and the events. Forgets timers, queue and wire; what the stream reports of the
        /// session that ends is dropped from now on.
        private func finishSession(_ reason: SerialCloseReason) {
            let flight = onTheWire
            let waiting = queued
            flight?.timer.cancel()
            gapTimer?.cancel()
            gapTimer = nil
            inGap = false
            onTheWire = nil
            queued = []
            replyBuffer = Data()
            connection = .closed
            generation = bridge.advance()
            if let flight = flight {
                resolve(flight.outcome, .closed(reason))
            }
            for item in waiting {
                resolve(item.outcome, .closed(reason))
            }
            resolveOpenWaiters(.closed(reason))
            publish(.closed(reason))
            resumeIdleWaiters()
        }

        // MARK: Waiters and events

        private func addOpenWaiter() -> AsyncStream<OpenOutcome> {
            let (outcomes, continuation) = makeMailbox(OpenOutcome.self)
            openWaiters.append(continuation)
            return outcomes
        }

        private func resolveOpenWaiters(_ outcome: OpenOutcome) {
            let waiting = openWaiters
            openWaiters = []
            for continuation in waiting {
                continuation.yield(outcome)
                continuation.finish()
            }
        }

        private func resolve(_ continuation: AsyncStream<Outcome>.Continuation, _ outcome: Outcome) {
            continuation.yield(outcome)
            continuation.finish()
        }

        private func resumeIdleWaiters() {
            let waiting = idleWaiters
            idleWaiters = []
            for waiter in waiting {
                waiter.continuation.yield(())
                waiter.continuation.finish()
            }
        }

        private func forgetIdleWaiter(_ id: Int) {
            idleWaiters.removeAll { $0.id == id }
        }

        private func publish(_ kind: SerialQueueEvent.Kind, bytes: Data? = nil, date: Date = Date()) {
            guard eventHub.hasConsumers else {
                return
            }
            eventHub.publish(SerialQueueEvent(date: date, kind: kind, bytes: bytes))
        }
    }

    // MARK: - Private support

    // `Data` and `Date` are `Sendable` in Apple's Foundation but not in the older Foundations of Linux,
    // so the types below that carry them say so themselves.

    /// What became of a request or a write.
    @available(macOS 10.15, *)
    private enum Outcome: @unchecked Sendable {
        case answered(Data)
        case timedOut
        case closed(SerialCloseReason)
        case cancelled
        case written
    }

    @available(macOS 10.15, *)
    private enum OpenOutcome: Sendable {
        case opened
        case closed(SerialCloseReason)
    }

    /// The streams ``SerialChannel/events()`` gave out. The channel publishes to them, one event after the
    /// other, from its own isolation; a consumer that stops takes its stream out from wherever it stops, so a
    /// lock keeps the table. Releasing the channel releases the hub, which ends every stream still in it.
    @available(macOS 10.15, *)
    private final class EventHub: @unchecked Sendable {
        private let lock = NSLock()
        private var streams: [Int: AsyncStream<SerialQueueEvent>.Continuation] = [:]
        private var nextID = 0

        deinit {
            finishAll()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return streams.count
        }

        var hasConsumers: Bool {
            return count > 0
        }

        func add(_ continuation: AsyncStream<SerialQueueEvent>.Continuation) -> Int {
            lock.lock()
            defer { lock.unlock() }
            nextID += 1
            streams[nextID] = continuation
            return nextID
        }

        func remove(_ id: Int) {
            lock.lock()
            streams[id] = nil
            lock.unlock()
        }

        func publish(_ event: SerialQueueEvent) {
            lock.lock()
            let consumers = Array(streams.values)
            lock.unlock()
            for continuation in consumers {
                continuation.yield(event)
            }
        }

        /// Ends every stream. A stream that ends calls `remove`, so the table is emptied first.
        private func finishAll() {
            lock.lock()
            let consumers = Array(streams.values)
            streams = [:]
            lock.unlock()
            for continuation in consumers {
                continuation.finish()
            }
        }
    }

    /// A weak reference a `@Sendable` closure can hold.
    @available(macOS 10.15, *)
    private final class WeakChannel: @unchecked Sendable {
        weak var object: SerialChannel?

        init(_ object: SerialChannel) {
            self.object = object
        }
    }

    @available(macOS 10.15, *)
    private final class WeakEventHub: @unchecked Sendable {
        weak var object: EventHub?

        init(_ object: EventHub) {
            self.object = object
        }
    }

    /// A request or a write in the queue, as its caller holds it.
    @available(macOS 10.15, *)
    private struct Ticket: @unchecked Sendable {
        let number: Int
        let outcomes: AsyncStream<Outcome>
        let cancellation: CancelFlag
    }

    /// Raised by the cancellation of a request's task, on the thread that cancels it, and read by the actor
    /// before it writes the request. The one thing about a cancellation the actor need not be asked for.
    @available(macOS 10.15, *)
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false

        var isRaised: Bool {
            lock.lock()
            defer { lock.unlock() }
            return raised
        }

        func raise() {
            lock.lock()
            raised = true
            lock.unlock()
        }
    }

    /// A stream, and the continuation that feeds it: how the actor hands a value to someone who waits for it.
    @available(macOS 10.15, *)
    private func makeMailbox<Element: Sendable>(_ type: Element.Type) -> (stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation) {
        var captured: AsyncStream<Element>.Continuation?
        let stream = AsyncStream<Element> { captured = $0 }
        guard let continuation = captured else {
            preconditionFailure("AsyncStream builds its continuation before it returns")
        }
        return (stream, continuation)
    }

    /// A task that waits for the first value of `stream`.
    ///
    /// It is a task of its own because a stream ends its iteration for a task that is cancelled: a caller
    /// that must go on waiting after its cancellation waits for this task instead, whose `value` does not
    /// give up.
    @available(macOS 10.15, *)
    private func firstValue<Element: Sendable>(of stream: AsyncStream<Element>, orElse fallback: Element) -> Task<Element, Never> {
        return Task {
            for await value in stream {
                return value
            }
            return fallback
        }
    }

    // The tasks below outlive the call that starts them and hold the channel only weakly, so they are made here,
    // outside the actor, and not in one of its methods: a task made there would run on the actor as its executor,
    // an actor it does not keep alive. They go through the channel only while they use it.
    //
    // Each has a priority of its own. A task made by a plain `Task { }` takes the priority of whoever makes it,
    // and the channel would run its pump and its timers at that of the first caller to open it or to make a
    // request, which may be a background task.

    /// Runs `fire` when the uptime clock reaches `deadline`, unless the task it returns is cancelled first.
    @available(macOS 10.15, *)
    private func startTimer(untilUptime deadline: UInt64, _ fire: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        return Task(priority: .userInitiated) {
            guard await sleep(untilUptime: deadline) else {
                return
            }
            await fire()
        }
    }

    /// Hands what the stream reports to the channel, one report after the other, until the bridge that
    /// makes them is released.
    @available(macOS 10.15, *)
    private func pumpReports(_ reports: AsyncStream<StreamBridge.Stamped>, into owner: WeakChannel) {
        Task(priority: .userInitiated) {
            for await report in reports {
                guard let channel = owner.object else {
                    return
                }
                await channel.handle(report)
            }
        }
    }

    /// Waits until the uptime clock reaches `deadline`. `false` if the task was cancelled first.
    @available(macOS 10.15, *)
    private func sleep(untilUptime deadline: UInt64) async -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        do {
            try await Task.sleep(nanoseconds: deadline > now ? deadline - now : 0)
            return true
        } catch {
            return false
        }
    }

    private func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard seconds > 0 else {
            return 0
        }
        return UInt64(min(seconds, 1_000_000_000) * 1_000_000_000)
    }

    /// Receives what the stream reports, on whatever thread it reports, and hands it to the actor through
    /// an `AsyncStream`: the one bridge between the stream's world and the actor's. Each report carries
    /// the session the actor was in when it was made, and its number among all the reports posted: the
    /// actor can tell, by numbers alone, what the stream reported before something the actor did.
    @available(macOS 10.15, *)
    private final class StreamBridge: SerialByteStreamDelegate, @unchecked Sendable {
        enum Report: @unchecked Sendable {
            case opened
            /// A chunk, with its arrival by the wall clock and by the monotonic clock, stamped before any hop.
            case received(Data, arrival: Date, monotonic: UInt64)
            case closed(SerialCloseReason)
        }

        struct Stamped: @unchecked Sendable {
            let generation: Int
            /// From 1, in the order the reports were posted.
            let sequence: Int
            let report: Report
        }

        let reports: AsyncStream<Stamped>
        private let continuation: AsyncStream<Stamped>.Continuation
        private let lock = NSLock()
        private var generation = 0
        private var sequence = 0

        /// How many reports have been posted so far: those numbered up to it were posted before this call.
        var posted: Int {
            lock.lock()
            defer { lock.unlock() }
            return sequence
        }

        init() {
            let (reports, continuation) = makeMailbox(Stamped.self)
            self.reports = reports
            self.continuation = continuation
        }

        deinit {
            continuation.finish()
        }

        /// Starts a new session and answers its number. Reports made from now on carry it.
        func advance() -> Int {
            lock.lock()
            defer { lock.unlock() }
            generation += 1
            return generation
        }

        func streamDidOpen(_ stream: SerialByteStream) {
            post(.opened)
        }

        func stream(_ stream: SerialByteStream, didReceive bytes: Data) {
            post(.received(bytes, arrival: Date(), monotonic: DispatchTime.now().uptimeNanoseconds))
        }

        func streamDidClose(_ stream: SerialByteStream, reason: SerialCloseReason) {
            post(.closed(reason))
        }

        /// Numbers, stamps and yields under one lock, so reports reach the actor in the order of their
        /// numbers, and `posted` is exact.
        private func post(_ report: Report) {
            lock.lock()
            sequence += 1
            continuation.yield(Stamped(generation: generation, sequence: sequence, report: report))
            lock.unlock()
        }
    }

#endif
