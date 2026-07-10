// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BO3MacCalibrator",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "bo3-mac-calibrator", targets: ["BO3MacCalibrator"])
    ],
    targets: [
        .executableTarget(
            name: "BO3MacCalibrator",
            path: "Sources/BO3MacCalibrator"
        )
    ]
)
