//
//  SerialPortMonitor.swift
//  SerialPortSwift
//

#if os(macOS)

    import AppKit
    import Foundation
    import IOKit
    import IOKit.serial

    /// What a ``SerialPortMonitor`` tells its owner. Called on the main thread.
    public protocol SerialPortMonitorDelegate: AnyObject {
        func serialPortMonitor(_ monitor: SerialPortMonitor, didConnect ports: [SerialPortDescriptor])
        func serialPortMonitor(_ monitor: SerialPortMonitor, didDisconnect ports: [SerialPortDescriptor])
        /// The Mac is about to sleep: close open ports now, and reopen them on wake.
        func serialPortMonitorSystemWillSleep(_ monitor: SerialPortMonitor)
        func serialPortMonitorSystemDidWake(_ monitor: SerialPortMonitor)
    }

    /// Lists the Mac's serial ports and says when one is plugged in or removed, and when the Mac
    /// sleeps and wakes.
    ///
    /// Every `IOSerialBSDClient` counts, of every type. A port's name is its `IOTTYDevice` and its path
    /// its `IOCalloutDevice`. Create it, and use it, on the main thread: notifications arrive on the
    /// main run loop.
    public final class SerialPortMonitor {
        public weak var delegate: SerialPortMonitorDelegate?

        private var notificationPort: IONotificationPortRef?
        private var runLoopSource: CFRunLoopSource?
        private var publishIterator: io_iterator_t = 0
        private var terminateIterator: io_iterator_t = 0
        private var workspaceObservers: [NSObjectProtocol] = []

        /// The ports present now, by their registry entry ID. A port that is unplugged is found here
        /// even though the system no longer answers questions about it.
        private var portsByEntryID: [UInt64: SerialPortDescriptor] = [:]

        /// The callbacks are C function pointers: they capture nothing, and find the monitor again
        /// through `refcon`.
        private static let publishCallback: IOServiceMatchingCallback = { refcon, iterator in
            if let monitor = SerialPortMonitor.monitor(from: refcon) {
                monitor.portsWerePublished(iterator, reportsToDelegate: true)
            }
        }

        private static let terminateCallback: IOServiceMatchingCallback = { refcon, iterator in
            if let monitor = SerialPortMonitor.monitor(from: refcon) {
                monitor.portsWereTerminated(iterator, reportsToDelegate: true)
            }
        }

        public init() {
            self.startWatchingPorts()
            self.startWatchingSleepAndWake()
        }

        deinit {
            let center = NSWorkspace.shared.notificationCenter
            for observer in self.workspaceObservers {
                center.removeObserver(observer)
            }
            self.workspaceObservers.removeAll()

            if self.publishIterator != 0 {
                IOObjectRelease(self.publishIterator)
                self.publishIterator = 0
            }
            if self.terminateIterator != 0 {
                IOObjectRelease(self.terminateIterator)
                self.terminateIterator = 0
            }
            if let source = self.runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.defaultMode)
                self.runLoopSource = nil
            }
            if let port = self.notificationPort {
                IONotificationPortDestroy(port)
                self.notificationPort = nil
            }
        }

        /// The ports present now, sorted by name.
        public var availablePorts: [SerialPortDescriptor] {
            return SerialPortMonitor.sortedByName(Array(self.portsByEntryID.values))
        }

        // MARK: - Setup

        private func startWatchingPorts() {
            // `0` is the default main port: `kIOMasterPortDefault` is deprecated on new SDKs, and
            // `kIOMainPortDefault` does not exist on old ones.
            guard let port = IONotificationPortCreate(0) else {
                return
            }
            self.notificationPort = port

            if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
                self.runLoopSource = source
                CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.defaultMode)
            }

            let refcon = Unmanaged.passUnretained(self).toOpaque()

            // Each registration consumes its matching dictionary, so each gets a new one.
            var publish: io_iterator_t = 0
            if let matching = SerialPortMonitor.makeMatchingDictionary() {
                let status = IOServiceAddMatchingNotification(
                    port,
                    kIOPublishNotification,
                    matching,
                    SerialPortMonitor.publishCallback,
                    refcon,
                    &publish
                )
                if status == KERN_SUCCESS {
                    self.publishIterator = publish
                }
            }

            var terminate: io_iterator_t = 0
            if let matching = SerialPortMonitor.makeMatchingDictionary() {
                let status = IOServiceAddMatchingNotification(
                    port,
                    kIOTerminatedNotification,
                    matching,
                    SerialPortMonitor.terminateCallback,
                    refcon,
                    &terminate
                )
                if status == KERN_SUCCESS {
                    self.terminateIterator = terminate
                }
            }

            // Draining an iterator is what arms its notification. The first drain of the publish
            // iterator lists the ports that are already there, and nobody is told about those.
            if self.publishIterator != 0 {
                self.portsWerePublished(self.publishIterator, reportsToDelegate: false)
            }
            if self.terminateIterator != 0 {
                self.portsWereTerminated(self.terminateIterator, reportsToDelegate: false)
            }
        }

        private func startWatchingSleepAndWake() {
            let center = NSWorkspace.shared.notificationCenter

            let willSleep = center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: OperationQueue.main
            ) { [weak self] _ in
                guard let self = self else {
                    return
                }
                self.delegate?.serialPortMonitorSystemWillSleep(self)
            }

            let didWake = center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: OperationQueue.main
            ) { [weak self] _ in
                guard let self = self else {
                    return
                }
                self.delegate?.serialPortMonitorSystemDidWake(self)
            }

            self.workspaceObservers = [willSleep, didWake]
        }

        // MARK: - Notifications

        private static func monitor(from refcon: UnsafeMutableRawPointer?) -> SerialPortMonitor? {
            guard let refcon = refcon else {
                return nil
            }
            return Unmanaged<SerialPortMonitor>.fromOpaque(refcon).takeUnretainedValue()
        }

        private func portsWerePublished(_ iterator: io_iterator_t, reportsToDelegate: Bool) {
            var connected: [SerialPortDescriptor] = []

            SerialPortMonitor.forEachService(in: iterator) { service in
                var entryID: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else {
                    return
                }
                guard let descriptor = SerialPortMonitor.descriptor(of: service) else {
                    return
                }
                // A service that publishes again under an entry ID already listed is not a new
                // connection: its description is refreshed, and the delegate is not told again.
                let isNew = self.portsByEntryID[entryID] == nil
                self.portsByEntryID[entryID] = descriptor
                if isNew {
                    connected.append(descriptor)
                }
            }

            if reportsToDelegate && !connected.isEmpty {
                self.delegate?.serialPortMonitor(self, didConnect: SerialPortMonitor.sortedByName(connected))
            }
        }

        private func portsWereTerminated(_ iterator: io_iterator_t, reportsToDelegate: Bool) {
            var disconnected: [SerialPortDescriptor] = []

            SerialPortMonitor.forEachService(in: iterator) { service in
                var entryID: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else {
                    return
                }
                if let descriptor = self.portsByEntryID.removeValue(forKey: entryID) {
                    disconnected.append(descriptor)
                }
            }

            if reportsToDelegate && !disconnected.isEmpty {
                self.delegate?.serialPortMonitor(self, didDisconnect: SerialPortMonitor.sortedByName(disconnected))
            }
        }

        // MARK: - IOKit helpers

        /// A new matching dictionary for every serial BSD client, of every type.
        private static func makeMatchingDictionary() -> CFMutableDictionary? {
            guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else {
                return nil
            }
            let bridged = matching as NSMutableDictionary
            bridged[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes
            return matching
        }

        /// Hands each service of `iterator` to `body` and releases it afterwards, until the iterator
        /// has no more.
        private static func forEachService(in iterator: io_iterator_t, _ body: (io_object_t) -> Void) {
            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 {
                    return
                }
                defer { IOObjectRelease(service) }
                body(service)
            }
        }

        /// The port a service stands for, or `nil` when it has no name or no callout path.
        private static func descriptor(of service: io_object_t) -> SerialPortDescriptor? {
            guard
                let name = SerialPortMonitor.stringProperty(kIOTTYDeviceKey, of: service),
                let calloutPath = SerialPortMonitor.stringProperty(kIOCalloutDeviceKey, of: service)
            else {
                return nil
            }
            let dialinPath = SerialPortMonitor.stringProperty(kIODialinDeviceKey, of: service)
            return SerialPortDescriptor(name: name, calloutPath: calloutPath, dialinPath: dialinPath)
        }

        private static func stringProperty(_ key: String, of service: io_object_t) -> String? {
            let property = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
            guard let value = property?.takeRetainedValue() as? String, !value.isEmpty else {
                return nil
            }
            return value
        }

        private static func sortedByName(_ ports: [SerialPortDescriptor]) -> [SerialPortDescriptor] {
            return ports.sorted { first, second in
                if first.name != second.name {
                    return first.name < second.name
                }
                return first.calloutPath < second.calloutPath
            }
        }
    }

#endif
