// swift-tools-version:5.1
//
//  The language ceiling is Swift 5.1 and the deployment floor is macOS 10.11: see CONTRIBUTING.md.
//

import PackageDescription

let package = Package(
    name: "SerialPortSwift",
    platforms: [
        .macOS(.v10_11)
    ],
    products: [
        /// The serial port, its discovery, and the request/response queue.
        .library(name: "SerialPortSwift", targets: ["SerialPortSwift"]),
        /// Stand-ins for a real device: a simulated device, a scripted replay and a pseudo-terminal.
        /// For tests and simulators; an app does not need it in its shipping build.
        .library(name: "SerialPortSwiftSimulation", targets: ["SerialPortSwiftSimulation"]),
        /// The request/response channel as an actor with async/await. Needs Swift 5.7 and macOS 10.15;
        /// with an older compiler it builds empty, so the rest of the package keeps its Swift 5.1 floor.
        .library(name: "SerialPortSwiftConcurrency", targets: ["SerialPortSwiftConcurrency"])
    ],
    targets: [
        .target(name: "SerialPortSwift"),
        .target(name: "SerialPortSwiftSimulation", dependencies: ["SerialPortSwift"]),
        .target(name: "SerialPortSwiftConcurrency", dependencies: ["SerialPortSwift"]),
        .testTarget(name: "SerialPortSwiftTests", dependencies: ["SerialPortSwift", "SerialPortSwiftSimulation"]),
        .testTarget(
            name: "SerialPortSwiftConcurrencyTests",
            dependencies: ["SerialPortSwiftConcurrency", "SerialPortSwift", "SerialPortSwiftSimulation"]
        )
    ]
)
