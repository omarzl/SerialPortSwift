//
//  SerialPortMonitorTests.swift
//  SerialPortSwiftTests
//

#if os(macOS)

    import Foundation
    import SerialPortSwift
    import XCTest

    /// These run on machines with any number of serial ports, none included: they check the shape of
    /// what the system lists, not which ports there are.
    final class SerialPortMonitorTests: XCTestCase {
        func testCreatingAndReleasingMonitorsInALoopDoesNotCrash() {
            for _ in 0..<50 {
                autoreleasepool {
                    let monitor = SerialPortMonitor()
                    _ = monitor.availablePorts
                }
            }
        }

        func testAMonitorReleasedWhileItsNotificationsAreStillQueuedDoesNotCrash() {
            for _ in 0..<10 {
                autoreleasepool {
                    let monitor = SerialPortMonitor()
                    _ = monitor
                }
                // Let the main run loop run what the monitors left behind.
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
        }

        func testAvailablePortsAreSortedByName() {
            let monitor = SerialPortMonitor()
            let names = monitor.availablePorts.map { $0.name }

            XCTAssertEqual(names, names.sorted())
        }

        func testEveryPortHasANameAndACalloutPathUnderDev() {
            let monitor = SerialPortMonitor()

            for port in monitor.availablePorts {
                XCTAssertFalse(port.name.isEmpty)
                XCTAssertTrue(port.calloutPath.hasPrefix("/dev/"), "\(port.calloutPath) is not under /dev/")
                if let dialinPath = port.dialinPath {
                    XCTAssertTrue(dialinPath.hasPrefix("/dev/"), "\(dialinPath) is not under /dev/")
                }
            }
        }
    }

#endif
