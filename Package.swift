// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "QuotaPilot", platforms: [.macOS(.v13)], products: [
    .executable(name: "QuotaPilot", targets: ["UsageWidget"])
], targets: [
    .target(name: "UsageCore"),
    .target(name: "UsageTransport", dependencies: ["UsageCore"]),
    .executableTarget(name: "UsageWidget", dependencies: ["UsageCore", "UsageTransport"]),
    .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore", "UsageTransport"])
])
