// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppSweep",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AppSweep", targets: ["AppSweep"]),
        .library(name: "AppSweepCore", targets: ["AppSweepCore"]),
        .executable(name: "AppSweepSafetyChecks", targets: ["AppSweepSafetyChecks"])
    ],
    targets: [
        .target(name: "AppSweepCore"),
        .executableTarget(
            name: "AppSweep",
            dependencies: ["AppSweepCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "AppSweepSafetyChecks", dependencies: ["AppSweepCore"],
                          path: "Tests/AppSweepCoreTests")
    ]
)
