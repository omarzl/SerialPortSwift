//
//  SerialPortDescriptorTests.swift
//  SerialPortSwiftTests
//

import SerialPortSwift
import XCTest

final class SerialPortDescriptorTests: XCTestCase {
    func testTheDialinPathIsOptional() {
        let descriptor = SerialPortDescriptor(name: "usbserial-1420", calloutPath: "/dev/cu.usbserial-1420")

        XCTAssertEqual(descriptor.name, "usbserial-1420")
        XCTAssertEqual(descriptor.calloutPath, "/dev/cu.usbserial-1420")
        XCTAssertNil(descriptor.dialinPath)
    }

    func testAllThreeFieldsAreKept() {
        let descriptor = SerialPortDescriptor(
            name: "usbserial-1420",
            calloutPath: "/dev/cu.usbserial-1420",
            dialinPath: "/dev/tty.usbserial-1420"
        )

        XCTAssertEqual(descriptor.dialinPath, "/dev/tty.usbserial-1420")
    }

    func testDescriptorsWithTheSameFieldsAreEqual() {
        let first = SerialPortDescriptor(name: "a", calloutPath: "/dev/cu.a", dialinPath: "/dev/tty.a")
        let second = SerialPortDescriptor(name: "a", calloutPath: "/dev/cu.a", dialinPath: "/dev/tty.a")

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.hashValue, second.hashValue)
    }

    func testEachFieldTellsDescriptorsApart() {
        let base = SerialPortDescriptor(name: "a", calloutPath: "/dev/cu.a", dialinPath: "/dev/tty.a")

        XCTAssertNotEqual(base, SerialPortDescriptor(name: "b", calloutPath: "/dev/cu.a", dialinPath: "/dev/tty.a"))
        XCTAssertNotEqual(base, SerialPortDescriptor(name: "a", calloutPath: "/dev/cu.b", dialinPath: "/dev/tty.a"))
        XCTAssertNotEqual(base, SerialPortDescriptor(name: "a", calloutPath: "/dev/cu.a", dialinPath: "/dev/tty.b"))
        XCTAssertNotEqual(base, SerialPortDescriptor(name: "a", calloutPath: "/dev/cu.a"))
    }

    func testDescriptorsWorkAsSetMembersAndDictionaryKeys() {
        let first = SerialPortDescriptor(name: "a", calloutPath: "/dev/cu.a")
        let duplicate = SerialPortDescriptor(name: "a", calloutPath: "/dev/cu.a")
        let other = SerialPortDescriptor(name: "b", calloutPath: "/dev/cu.b")

        XCTAssertEqual(Set([first, duplicate, other]).count, 2)

        var labels: [SerialPortDescriptor: String] = [:]
        labels[first] = "first"
        labels[duplicate] = "duplicate"
        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(labels[first], "duplicate")
    }
}
