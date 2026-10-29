//
//  SerialPortMonitor.swift
//  SerialPortSwift
//

#if os(macOS)

    import Foundation

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

        public init() {
            fatalError("Not implemented yet")
        }

        /// The ports present now, sorted by name.
        public var availablePorts: [SerialPortDescriptor] {
            fatalError("Not implemented yet")
        }
    }

#endif
