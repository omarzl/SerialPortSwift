//
//  SerialExchangeTests.swift
//  SerialPortSwiftTests
//

import SerialPortSwift
import XCTest

final class SerialExchangeTests: XCTestCase {
    func testAnExchangeWithoutItsOwnTimeoutLeavesItToTheTransport() {
        let exchange = SerialExchange(id: SerialExchangeID(number: 7), frame: Data([0x41]), reply: .exactly(1))

        XCTAssertNil(exchange.timeout)
        XCTAssertEqual(exchange.id, SerialExchangeID(number: 7))
        XCTAssertEqual(exchange.reply, .exactly(1))
    }
}
