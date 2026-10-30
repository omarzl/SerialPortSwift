//
//  SerialChannelTests.swift
//  SerialPortSwiftConcurrencyTests
//

#if compiler(>=5.5) && canImport(_Concurrency)

    import SerialPortSwift
    import SerialPortSwiftConcurrency
    import XCTest

    @available(macOS 10.15, *)
    final class SerialChannelTests: XCTestCase {
        func testTheConfigurationStartsWithTheQueuesDefaults() {
            let configuration = SerialChannel.Configuration()

            XCTAssertEqual(configuration.defaultTimeout, 1)
            XCTAssertEqual(configuration.maximumReplyLength, 64)
            XCTAssertEqual(configuration.postTimeoutGap, 0.1)
        }
    }

#endif
