// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacTurnCalibrator",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "mac-turn-calibrator", targets: ["MacTurnCalibrator"])
    ],
    targets: [
        .executableTarget(
            name: "MacTurnCalibrator",
            path: "Sources/MacTurnCalibrator"
        )
    ]
)
