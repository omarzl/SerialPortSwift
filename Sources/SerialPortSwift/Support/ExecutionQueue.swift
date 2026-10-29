//
//  ExecutionQueue.swift
//  SerialPortSwift
//

import Foundation

/// A dispatch queue that knows whether the current code is running on it, so work can run inline
/// there and be dispatched from anywhere else. Several wrappers may share one queue: each marks it
/// with its own key.
///
/// `dispatchPrecondition` would say the same, but it needs macOS 10.12.
final class ExecutionQueue {
    let queue: DispatchQueue
    private let key = DispatchSpecificKey<UInt8>()

    init(queue: DispatchQueue) {
        self.queue = queue
        queue.setSpecific(key: key, value: 1)
    }

    convenience init(label: String) {
        self.init(queue: DispatchQueue(label: label))
    }

    deinit {
        queue.setSpecific(key: key, value: nil)
    }

    /// Whether the calling code runs on this queue.
    var isCurrent: Bool {
        return DispatchQueue.getSpecific(key: key) != nil
    }

    /// Runs `work` here and waits for it: inline when already here, through `sync` otherwise.
    func sync<T>(_ work: () throws -> T) rethrows -> T {
        if isCurrent {
            return try work()
        }
        return try queue.sync(execute: work)
    }

    /// Runs `work` here later, even when already here.
    func async(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    /// Runs `work` inline when already here, and later otherwise.
    func run(_ work: @escaping () -> Void) {
        if isCurrent {
            work()
        } else {
            queue.async(execute: work)
        }
    }

    func asyncAfter(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
