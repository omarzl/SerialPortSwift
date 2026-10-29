//
//  WeakObserverSet.swift
//  SerialPortSwift
//

import Foundation

/// The observers of one ``SerialRequestQueue``, held weakly. Safe to change from any thread; an
/// observer added twice is held once.
final class WeakObserverSet {
    private struct Entry {
        weak var observer: SerialQueueObserver?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func add(_ observer: SerialQueueObserver) {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { $0.observer != nil }
        if !entries.contains(where: { $0.observer === observer }) {
            entries.append(Entry(observer: observer))
        }
    }

    func remove(_ observer: SerialQueueObserver) {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { $0.observer != nil && $0.observer !== observer }
    }

    /// The observers alive now, in the order they were added. Call them outside any lock.
    func snapshot() -> [SerialQueueObserver] {
        lock.lock()
        defer { lock.unlock() }
        return entries.compactMap { $0.observer }
    }
}
