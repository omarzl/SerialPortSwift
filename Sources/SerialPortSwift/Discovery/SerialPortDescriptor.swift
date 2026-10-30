//
//  SerialPortDescriptor.swift
//  SerialPortSwift
//

import Foundation

/// A serial port the system lists.
public struct SerialPortDescriptor: Hashable {
    /// The port's name as the driver gives it: `usbserial-1420`, `Bluetooth-Incoming-Port`.
    public let name: String
    /// The device to open: `/dev/cu.usbserial-1420`.
    public let calloutPath: String
    /// The dial-in device, when the system has one: `/dev/tty.usbserial-1420`.
    public let dialinPath: String?

    public init(name: String, calloutPath: String, dialinPath: String? = nil) {
        self.name = name
        self.calloutPath = calloutPath
        self.dialinPath = dialinPath
    }
}
