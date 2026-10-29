//
//  ReplayByteStream.swift
//  SerialPortSwiftSimulation
//

import Foundation
import SerialPortSwift

/// Bytes a ``ReplayByteStream`` delivers, and when: `offset` seconds after the moment it is measured
/// from.
public struct ReplayChunk: Equatable {
    public let bytes: Data
    public let offset: TimeInterval

    public init(_ bytes: Data, at offset: TimeInterval = 0) {
        self.bytes = bytes
        self.offset = offset
    }
}

/// One step of a replay script: the next write, and what the device answers to it.
public struct ReplayStep: Equatable {
    /// What the write should be, or `nil` to accept any.
    public let expected: Data?
    /// The chunks delivered after that write, each at its offset from the moment of the write.
    public let replies: [ReplayChunk]

    public init(expecting expected: Data? = nil, replies: [ReplayChunk]) {
        self.expected = expected
        self.replies = replies
    }

    /// The next write is answered with `chunks`.
    public static func reply(to expected: Data? = nil, with chunks: [ReplayChunk]) -> ReplayStep {
        return ReplayStep(expecting: expected, replies: chunks)
    }

    /// The next write gets no answer.
    public static func silence(after expected: Data? = nil) -> ReplayStep {
        return ReplayStep(expecting: expected, replies: [])
    }
}

/// A write a ``ReplayByteStream`` received.
public struct ReplayWrite: Equatable {
    public let date: Date
    public let bytes: Data
    /// Whether a script step was waiting for it and its bytes were the ones expected. A write that
    /// arrives with the script used up, or that differs from the step's `expected`, is `false`.
    public let matchedExpectation: Bool

    public init(date: Date, bytes: Data, matchedExpectation: Bool) {
        self.date = date
        self.bytes = bytes
        self.matchedExpectation = matchedExpectation
    }
}

/// A ``SerialByteStream`` that plays a script: recorded or written-by-hand traffic, with its timing.
/// Built for driving a ``SerialRequestQueue`` in tests.
///
/// Each write uses up the next ``ReplayStep``, whose replies are then delivered at their offsets from
/// that write — even while an earlier step's replies are still on their way. A write that arrives
/// with the script used up is recorded and gets no answer. Bytes and closes the script does not tie
/// to a write are pushed with ``receive(_:after:)`` and ``end(_:after:)``.
///
/// Open and close report synchronously, before they return.
public final class ReplayByteStream: SerialByteStream {
    public let name: String
    public weak var delegate: SerialByteStreamDelegate?

    /// Something to do at a moment, in order of `due` and then of `sequence`.
    private struct Scheduled {
        let due: UInt64
        let sequence: Int
        let generation: Int
        let action: () -> Void
    }

    private let openFailure: SerialStreamError?
    private let queue: DispatchQueue

    // The state below is guarded by `lock`, which is never held while calling the delegate.
    private let lock = NSLock()
    private var script: [ReplayStep]
    private var recorded: [ReplayWrite] = []
    private var opened = false
    private var generation = 0
    private var scheduled: [Scheduled] = []
    private var nextSequence = 0

    /// - Parameters:
    ///   - openFailure: when set, `open()` fails with it instead of opening.
    public init(
        name: String = "replay",
        script: [ReplayStep] = [],
        openFailure: SerialStreamError? = nil,
        queue: DispatchQueue? = nil
    ) {
        self.name = name
        self.script = script
        self.openFailure = openFailure
        self.queue = queue ?? DispatchQueue(label: "SerialPortSwiftSimulation.ReplayByteStream")
    }

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    /// Adds steps at the end of the script.
    public func append(_ steps: [ReplayStep]) {
        lock.lock()
        script.append(contentsOf: steps)
        lock.unlock()
    }

    /// Delivers `bytes` `delay` seconds from now, as one chunk, whatever the script says. Ignored if
    /// the stream is closed by then.
    public func receive(_ bytes: Data, after delay: TimeInterval = 0) {
        lock.lock()
        let item = insert(at: ReplayByteStream.now() &+ ReplayByteStream.nanoseconds(delay)) { [weak self] in
            if let self = self {
                self.delegate?.stream(self, didReceive: bytes)
            }
        }
        lock.unlock()
        arm(item)
    }

    /// Closes the stream `delay` seconds from now, as if the device did it: reported with `reason`.
    public func end(_ reason: SerialCloseReason, after delay: TimeInterval = 0) {
        lock.lock()
        let item = insert(at: ReplayByteStream.now() &+ ReplayByteStream.nanoseconds(delay)) { [weak self] in
            if let self = self {
                self.finish(with: reason)
            }
        }
        lock.unlock()
        arm(item)
    }

    /// Every write so far, in order.
    public var writes: [ReplayWrite] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Steps not yet used up by a write.
    public var remainingSteps: Int {
        lock.lock()
        defer { lock.unlock() }
        return script.count
    }

    public func open() {
        lock.lock()
        let wasOpen = opened
        let failure = openFailure
        if !wasOpen && failure == nil {
            opened = true
        }
        lock.unlock()
        if wasOpen {
            return
        }
        if let failure = failure {
            delegate?.streamDidClose(self, reason: .failed(failure))
        } else {
            delegate?.streamDidOpen(self)
        }
    }

    public func close() {
        finish(with: .requested)
    }

    public func write(_ bytes: Data) {
        queue.async { [weak self] in
            self?.record(bytes)
        }
    }

    // MARK: - Private

    /// Closes the stream, cancels everything still on its way and reports `reason` — unless it is
    /// closed already.
    private func finish(with reason: SerialCloseReason) {
        lock.lock()
        let wasOpen = opened
        if wasOpen {
            opened = false
            generation += 1
            scheduled.removeAll()
        }
        lock.unlock()
        if wasOpen {
            delegate?.streamDidClose(self, reason: reason)
        }
    }

    /// Notes a write and schedules the replies of the step it uses up. Runs on `queue`.
    private func record(_ bytes: Data) {
        lock.lock()
        guard opened else {
            lock.unlock()
            return
        }
        let arrival = ReplayByteStream.now()
        var matched = false
        var replies: [ReplayChunk] = []
        if !script.isEmpty {
            let step = script.removeFirst()
            matched = step.expected == nil || step.expected == bytes
            replies = step.replies
        }
        recorded.append(ReplayWrite(date: Date(), bytes: bytes, matchedExpectation: matched))
        var items: [Scheduled] = []
        for reply in replies {
            let due = arrival &+ ReplayByteStream.nanoseconds(reply.offset)
            items.append(insert(at: due) { [weak self] in
                if let self = self {
                    self.delegate?.stream(self, didReceive: reply.bytes)
                }
            })
        }
        lock.unlock()
        for item in items {
            arm(item)
        }
    }

    /// Notes that `action` is due at `due`, ahead of anything due later. Call with `lock` held, then
    /// `arm` the result once it is released.
    private func insert(at due: UInt64, _ action: @escaping () -> Void) -> Scheduled {
        nextSequence += 1
        let item = Scheduled(due: due, sequence: nextSequence, generation: generation, action: action)
        let position = scheduled.firstIndex { ReplayByteStream.isBefore(item, $0) } ?? scheduled.count
        scheduled.insert(item, at: position)
        return item
    }

    /// Starts the timer that runs `item` on `queue`.
    private func arm(_ item: Scheduled) {
        queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: item.due)) { [weak self] in
            self?.run(through: item)
        }
    }

    /// Runs, on `queue`, every action due up to and including `last`, earliest first — so chunks due
    /// together arrive in the order they were scheduled, whichever timer fires first. An action
    /// runs only if the stream is open and was not closed since it was scheduled.
    private func run(through last: Scheduled) {
        while true {
            lock.lock()
            guard let next = scheduled.first, !ReplayByteStream.isBefore(last, next) else {
                lock.unlock()
                return
            }
            scheduled.removeFirst()
            let current = opened && next.generation == generation
            lock.unlock()
            if current {
                next.action()
            }
        }
    }

    private static func isBefore(_ first: Scheduled, _ second: Scheduled) -> Bool {
        if first.due != second.due {
            return first.due < second.due
        }
        return first.sequence < second.sequence
    }

    private static func now() -> UInt64 {
        return DispatchTime.now().uptimeNanoseconds
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard seconds > 0 else {
            return 0
        }
        return UInt64(min(seconds, 1_000_000_000) * 1_000_000_000)
    }
}
