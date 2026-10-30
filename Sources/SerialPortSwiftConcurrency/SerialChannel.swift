//
//  SerialChannel.swift
//  SerialPortSwiftConcurrency
//
//  The request/response channel of `SerialRequestQueue`, written for Swift concurrency: an actor whose
//  callers `await` their reply. A second engine, not a wrapper: it shares the library's streams and its
//  reply rule (`ReplyMatcher`), and keeps its own state the way an actor does.
//
//  No `withCheckedContinuation`, `withCheckedThrowingContinuation` or unsafe continuation anywhere in
//  this module. A stream reports through its delegate on its own queue; those reports enter the actor
//  through an `AsyncStream`, the one bridge between the two worlds.
//

#if compiler(>=5.5) && canImport(_Concurrency)

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
    ///   of the queue, and the request throws `CancellationError`. A request already on the wire is
    ///   left to its reply or its timeout — the device answers it either way — and returns or throws as
    ///   usual.
    /// - **Closing.** ``close()`` and a close the stream reports on its own (the device removed, a
    ///   failure) end every request still waiting or on the wire with
    ///   ``SerialChannelError/closed(_:)``.
    ///
    /// The stream it is given becomes the channel's: the channel is its delegate.
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

        public init(stream: SerialByteStream, matcher: ReplyMatcher = TailScanMatcher(), configuration: Configuration = Configuration()) {
            self.name = stream.name
            fatalError("Not implemented yet")
        }

        public var isOpen: Bool {
            fatalError("Not implemented yet")
        }

        /// The pause after a timeout. Starts at ``Configuration/postTimeoutGap``; a change applies from
        /// the next timeout.
        public var postTimeoutGap: TimeInterval {
            fatalError("Not implemented yet")
        }

        public func setPostTimeoutGap(_ gap: TimeInterval) {
            fatalError("Not implemented yet")
        }

        /// Opens the stream and returns once it is open. Throws ``SerialChannelError/closed(_:)`` with
        /// the stream's reason when it cannot open. Opening an open channel does nothing.
        public func open() async throws {
            fatalError("Not implemented yet")
        }

        /// Closes the stream. Every request still waiting or on the wire throws
        /// ``SerialChannelError/closed(_:)`` with `.requested`. Closing a closed channel does nothing.
        public func close() async {
            fatalError("Not implemented yet")
        }

        /// Writes the exchange's frame when its turn comes and returns its reply, raw, exactly as
        /// received. Throws ``SerialChannelError/notOpen``, ``SerialChannelError/timedOut``,
        /// ``SerialChannelError/closed(_:)``, or `CancellationError` (see the type's notes).
        public func request(_ exchange: SerialExchange) async throws -> Data {
            fatalError("Not implemented yet")
        }

        /// A request whose id the channel picks.
        public func request(_ frame: Data, reply: ReplyShape, timeout: TimeInterval? = nil) async throws -> Data {
            fatalError("Not implemented yet")
        }

        /// Writes `frame` when its turn comes, without waiting for a reply, and returns once it has been
        /// handed to the stream. Throws ``SerialChannelError/notOpen``, ``SerialChannelError/closed(_:)``
        /// or `CancellationError` (cancelled before its turn).
        public func send(_ frame: Data) async throws {
            fatalError("Not implemented yet")
        }

        /// Returns once nothing is queued and nothing is on the wire — at once if that is already so,
        /// or if the channel is closed.
        public func waitUntilIdle() async {
            fatalError("Not implemented yet")
        }

        /// Everything that happens on the channel from now on, in order: the same events a
        /// ``SerialRequestQueue`` gives its observers. Each call returns a stream of its own; it ends when
        /// the caller stops iterating or the channel is released.
        public func events() -> AsyncStream<SerialQueueEvent> {
            fatalError("Not implemented yet")
        }
    }

#endif
