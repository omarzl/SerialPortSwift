//
//  SerialRequestQueue.swift
//  SerialPortSwift
//

import Foundation

/// A ``SerialTransport`` over any ``SerialByteStream``: a FIFO of requests with one exchange on the
/// wire at a time.
///
/// **Order.** Everything sent goes through one queue, in order: exchanges and writes without a reply
/// alike. A write without a reply is written as soon as its turn comes and the queue moves on. An
/// exchange is written, then nothing else is written until it is answered or times out.
///
/// **Replies.** Bytes received for the exchange on the wire are collected in a buffer of at most
/// ``Configuration/maximumReplyLength`` bytes (the oldest byte goes first; an exchange that expects
/// `.exactly(n)` keeps at least `n`) and handed to the ``ReplyMatcher`` after every byte. The first
/// reply it finds is delivered raw, the buffer is cleared and the next item is written. Bytes left
/// over in the same chunk after a reply are dropped (``SerialQueueEvent/Kind/unsolicitedBytesDropped``):
/// they arrived before the next frame was written, so they cannot answer it.
///
/// **Timeouts.** An exchange's timer starts when its frame is handed to the stream, so it includes
/// any time the stream takes to get earlier bytes out. When it fires, the delegate is told and the
/// queue pauses for ``postTimeoutGap``: bytes that arrive in that pause are late for the exchange that
/// timed out, and are published (``SerialQueueEvent/Kind/lateBytesDropped``) and dropped instead of
/// being credited to the next one. Timers run on the queue's own serial queue, so a busy delivery
/// queue cannot stretch them.
///
/// **Unsolicited bytes.** Bytes that arrive with no exchange on the wire are published and dropped.
///
/// **Closing.** `close()` stops the timer, drops everything queued and closes the stream. A close the
/// stream reports on its own (unplugged, failed) does the same. Either way the delegate hears
/// ``SerialTransportDelegate/transportDidClose(_:reason:)`` once, and nothing sent before the close
/// is reported after it. Sending on a closed queue does nothing. A `close()` that comes before the
/// stream has finished opening closes the queue at once, as a stream that is not open yet has
/// nothing to report; if the stream opens after all, the queue closes it again.
///
/// **Threads.** All state lives on one private serial queue. Delegate calls arrive on
/// ``Configuration/deliveryQueue``. When `open()` or `close()` is called on the delivery queue and the
/// stream reports synchronously, the delegate is told before the call returns.
/// ``SerialTransportDelegate/transportDidOpen(_:)`` is dropped if the queue has closed by the time it
/// would be delivered. Observers (``SerialQueueObserver``) are called on the serial queue. Call
/// `open()` and `close()` from any thread but the queue's own.
public final class SerialRequestQueue: SerialTransport {
    public struct Configuration {
        /// The timeout of an exchange that does not carry its own.
        public var defaultTimeout: TimeInterval
        /// The most bytes kept while waiting for a reply; older bytes are dropped first. An exchange
        /// that expects `.exactly(n)` keeps at least `n` bytes even when `n` is larger, so its reply
        /// can still be found.
        public var maximumReplyLength: Int
        /// The pause after a timeout during which late bytes are dropped. `0` for none.
        public var postTimeoutGap: TimeInterval
        /// Where delegate calls and ``SerialRequestQueue/whenIdle(_:)`` work run.
        public var deliveryQueue: DispatchQueue

        public init(
            defaultTimeout: TimeInterval = 1,
            maximumReplyLength: Int = 64,
            postTimeoutGap: TimeInterval = 0.1,
            deliveryQueue: DispatchQueue = .main
        ) {
            self.defaultTimeout = defaultTimeout
            self.maximumReplyLength = maximumReplyLength
            self.postTimeoutGap = postTimeoutGap
            self.deliveryQueue = deliveryQueue
        }
    }

    public let stream: SerialByteStream
    public let matcher: ReplyMatcher
    public let configuration: Configuration
    public weak var delegate: SerialTransportDelegate?

    private enum Connection {
        case closed
        case opening
        case open
        case closing
    }

    private enum Queued {
        case write(Data)
        case exchange(SerialExchange)
    }

    /// The exchange whose frame was written and whose reply is awaited. `token` names its timer.
    private struct OnTheWire {
        let exchange: SerialExchange
        let writtenAt: UInt64
        let token: Int
    }

    /// Receives what the stream reports and passes it on, so the queue itself is not a
    /// ``SerialByteStreamDelegate``. The queue owns it; it holds the queue weakly.
    private final class StreamListener: SerialByteStreamDelegate {
        weak var owner: SerialRequestQueue?

        func streamDidOpen(_ stream: SerialByteStream) {
            owner?.streamDidOpen()
        }

        func stream(_ stream: SerialByteStream, didReceive bytes: Data) {
            // Stamped here, before any hop, so the times are those of arrival.
            owner?.streamDidReceive(bytes, at: Date(), monotonic: DispatchTime.now().uptimeNanoseconds)
        }

        func streamDidClose(_ stream: SerialByteStream, reason: SerialCloseReason) {
            owner?.streamDidClose(reason)
        }
    }

    private let serial: ExecutionQueue
    private let delivery: ExecutionQueue
    private let observers = WeakObserverSet()
    private let listener = StreamListener()

    // Everything below is touched on `serial` only.
    private var connection = Connection.closed
    private var queued: [Queued] = []
    private var onTheWire: OnTheWire?
    private var replyBuffer = Data()
    private var gap: TimeInterval
    private var inGap = false
    private var timeoutToken = 0
    private var gapToken = 0
    /// Changes whenever a session ends, so nothing from before is reported after.
    private var generation = 0
    private var idleWaiters: [() -> Void] = []

    /// - Parameters:
    ///   - queue: the serial queue all state lives on. Pass the queue the stream reads on to save a
    ///     hop on every chunk received; by default the queue makes its own.
    public init(
        stream: SerialByteStream,
        matcher: ReplyMatcher = TailScanMatcher(),
        configuration: Configuration = Configuration(),
        queue: DispatchQueue? = nil
    ) {
        self.stream = stream
        self.matcher = matcher
        self.configuration = configuration
        if let queue = queue {
            self.serial = ExecutionQueue(queue: queue)
        } else {
            self.serial = ExecutionQueue(label: "SerialPortSwift.SerialRequestQueue")
        }
        self.delivery = ExecutionQueue(queue: configuration.deliveryQueue)
        self.gap = configuration.postTimeoutGap
        self.listener.owner = self
        stream.delegate = self.listener
    }

    public var name: String {
        return stream.name
    }

    public var isOpen: Bool {
        return serial.sync { self.connection == .open }
    }

    public var defaultTimeout: TimeInterval {
        return configuration.defaultTimeout
    }

    /// The pause after a timeout. Starts at ``Configuration/postTimeoutGap``; can be changed while the
    /// queue runs, and applies from the next timeout.
    public var postTimeoutGap: TimeInterval {
        get { return serial.sync { self.gap } }
        set { serial.sync { self.gap = newValue } }
    }

    public func open() {
        let shouldOpen = serial.sync { () -> Bool in
            guard self.connection == .closed else {
                return false
            }
            self.connection = .opening
            return true
        }
        if shouldOpen {
            stream.open()
        }
    }

    public func close() {
        let started = serial.sync { () -> (session: Int, wasOpening: Bool)? in
            guard self.connection != .closed && self.connection != .closing else {
                return nil
            }
            let wasOpening = self.connection == .opening
            self.connection = .closing
            self.endSession()
            return (self.generation, wasOpening)
        }
        guard let closing = started else {
            return
        }
        stream.close()
        if closing.wasOpening {
            // A stream that is not open yet reports nothing for `close()`. If it did not report, this
            // close is complete now; if it opens late, `streamDidOpen` closes it again.
            finishClose(.requested, onlyIfStillClosing: closing.session)
        }
    }

    public func send(_ exchange: SerialExchange) {
        enqueue(.exchange(exchange))
    }

    public func sendWithoutReply(_ frame: Data) {
        enqueue(.write(frame))
    }

    public func cancelQueuedExchanges() -> [SerialExchangeID] {
        return serial.sync { () -> [SerialExchangeID] in
            var cancelled: [SerialExchangeID] = []
            var kept: [Queued] = []
            for item in self.queued {
                switch item {
                case .exchange(let exchange):
                    cancelled.append(exchange.id)
                case .write:
                    kept.append(item)
                }
            }
            guard !cancelled.isEmpty else {
                return cancelled
            }
            self.queued = kept
            self.publish(.cancelled(cancelled))
            if self.isIdle {
                self.dispatchIdleWaiters()
            }
            return cancelled
        }
    }

    /// Runs `work` on the delivery queue as soon as nothing is queued and nothing is on the wire — at
    /// once if that is already so. A closed queue counts as idle.
    public func whenIdle(_ work: @escaping () -> Void) {
        serial.run {
            if self.connection == .closed || self.isIdle {
                self.delivery.async(work)
            } else {
                self.idleWaiters.append(work)
            }
        }
    }

    public func addObserver(_ observer: SerialQueueObserver) {
        observers.add(observer)
    }

    public func removeObserver(_ observer: SerialQueueObserver) {
        observers.remove(observer)
    }

    // MARK: - Queueing

    private func enqueue(_ item: Queued) {
        serial.run {
            guard self.connection == .open || self.connection == .opening else {
                return
            }
            self.queued.append(item)
            self.pump()
        }
    }

    /// Nothing queued and nothing on the wire.
    private var isIdle: Bool {
        return queued.isEmpty && onTheWire == nil
    }

    /// Writes what is next in line, until an exchange is on the wire or the line is empty.
    private func pump() {
        while connection == .open && onTheWire == nil && !inGap && !queued.isEmpty {
            switch queued.removeFirst() {
            case .write(let frame):
                stream.write(frame)
                publish(.sent(nil), bytes: frame)
            case .exchange(let exchange):
                replyBuffer = Data()
                stream.write(exchange.frame)
                let writtenAt = DispatchTime.now().uptimeNanoseconds
                timeoutToken += 1
                let token = timeoutToken
                onTheWire = OnTheWire(exchange: exchange, writtenAt: writtenAt, token: token)
                publish(.sent(exchange.id), bytes: exchange.frame)
                let timeout = exchange.timeout ?? configuration.defaultTimeout
                serial.asyncAfter(timeout) { [weak self] in
                    self?.timeoutFired(token)
                }
            }
        }
        if connection == .open && isIdle {
            dispatchIdleWaiters()
        }
    }

    private func timeoutFired(_ token: Int) {
        guard let flight = onTheWire, flight.token == token, connection == .open else {
            return
        }
        publish(.timedOut(flight.exchange.id), bytes: flight.exchange.frame)
        onTheWire = nil
        replyBuffer = Data()
        let expected = generation
        deliver(expecting: expected) { delegate in
            delegate.transport(self, didTimeOut: flight.exchange)
        }
        if gap > 0 {
            inGap = true
            gapToken += 1
            let gapEnd = gapToken
            serial.asyncAfter(gap) { [weak self] in
                self?.gapEnded(gapEnd)
            }
            if queued.isEmpty {
                dispatchIdleWaiters()
            }
        } else {
            pump()
        }
    }

    private func gapEnded(_ token: Int) {
        guard inGap, gapToken == token else {
            return
        }
        inGap = false
        pump()
    }

    // MARK: - Receiving

    private func streamDidReceive(_ chunk: Data, at date: Date, monotonic: UInt64) {
        serial.run {
            self.process(chunk, arrivedAt: date, monotonic: monotonic)
        }
    }

    private func process(_ chunk: Data, arrivedAt date: Date, monotonic: UInt64) {
        guard connection != .closed else {
            return
        }
        publish(.raw, bytes: chunk, date: date)
        if inGap {
            publish(.lateBytesDropped, bytes: chunk)
            return
        }
        guard let flight = onTheWire else {
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
            timeoutToken += 1
            let elapsed = monotonic > flight.writtenAt ? monotonic - flight.writtenAt : 0
            onTheWire = nil
            replyBuffer = Data()
            publish(.answered(flight.exchange.id, roundTrip: TimeInterval(elapsed) / 1_000_000_000), bytes: packet)
            let expected = generation
            deliver(expecting: expected) { delegate in
                delegate.transport(self, didAnswer: flight.exchange, with: packet)
            }
            if position + 1 < bytes.count {
                publish(.unsolicitedBytesDropped, bytes: Data(bytes[(position + 1)...]))
            }
            pump()
            return
        }
    }

    // MARK: - Stream events

    private enum OpenOutcome {
        /// The queue is open now; `session` names the session that opened.
        case opened(session: Int)
        /// The queue was closed (or closing) when the stream opened: it is closed again.
        case closeAgain
        case ignored
    }

    private func streamDidOpen() {
        let outcome = serial.sync { () -> OpenOutcome in
            switch self.connection {
            case .opening:
                self.connection = .open
                self.publish(.opened)
                return .opened(session: self.generation)
            case .closed, .closing:
                return .closeAgain
            case .open:
                return .ignored
            }
        }
        switch outcome {
        case .ignored:
            return
        case .closeAgain:
            // The close overtook the open. Whatever the stream reports for this is ignored.
            stream.close()
        case .opened(let session):
            delivery.run { [weak self] in
                guard let self = self else {
                    return
                }
                // A close may have been delivered ahead of this call: the delegate must not hear of
                // an open that is over.
                let stillOpen = self.serial.sync { self.generation == session && self.connection == .open }
                if stillOpen, let delegate = self.delegate {
                    delegate.transportDidOpen(self)
                }
            }
            serial.async {
                self.pump()
            }
        }
    }

    private func streamDidClose(_ reason: SerialCloseReason) {
        finishClose(reason, onlyIfStillClosing: nil)
    }

    /// Closes the queue, publishes it and tells the delegate, unless it is closed already. With
    /// `session` set, only if the close of that session is still waiting for the stream's report.
    private func finishClose(_ reason: SerialCloseReason, onlyIfStillClosing session: Int?) {
        let waiters = serial.sync { () -> [() -> Void]? in
            guard self.connection != .closed else {
                return nil
            }
            if let session = session, self.connection != .closing || self.generation != session {
                return nil
            }
            self.connection = .closed
            self.endSession()
            self.publish(.closed(reason))
            let waiting = self.idleWaiters
            self.idleWaiters = []
            return waiting
        }
        guard let idle = waiters else {
            return
        }
        delivery.run { [weak self] in
            if let self = self, let delegate = self.delegate {
                delegate.transportDidClose(self, reason: reason)
            }
        }
        for work in idle {
            delivery.async(work)
        }
    }

    /// Forgets everything of the session that ends: timers, what is queued, what is on the wire.
    private func endSession() {
        timeoutToken += 1
        gapToken += 1
        inGap = false
        onTheWire = nil
        replyBuffer = Data()
        queued = []
        generation += 1
    }

    // MARK: - Delivery and observers

    /// Calls the delegate on the delivery queue, later. The call is dropped when the session it
    /// belongs to (`generation`) has ended by then.
    private func deliver(expecting generation: Int, _ call: @escaping (SerialTransportDelegate) -> Void) {
        delivery.async { [weak self] in
            guard let self = self else {
                return
            }
            let current = self.serial.sync { self.generation }
            if current == generation, let delegate = self.delegate {
                call(delegate)
            }
        }
    }

    private func dispatchIdleWaiters() {
        let waiting = idleWaiters
        idleWaiters = []
        for work in waiting {
            delivery.async(work)
        }
    }

    private func publish(_ kind: SerialQueueEvent.Kind, bytes: Data? = nil, date: Date = Date()) {
        let watching = observers.snapshot()
        guard !watching.isEmpty else {
            return
        }
        let event = SerialQueueEvent(date: date, kind: kind, bytes: bytes)
        for observer in watching {
            observer.requestQueue(self, didLog: event)
        }
    }
}
