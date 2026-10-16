// swift-tools-version: 5.9
import PackageDescription

// The core, transport and `quotapilot` command-line tool build on macOS, Linux and Windows.
// The menu bar app (AppKit, SwiftUI Charts) is macOS-only.
var products: [Product] = [.executable(name: "quotapilot", targets: ["QuotaPilotCLI"])]
var targets: [Target] = [
    .target(name: "UsageCore"),
    .target(name: "UsageTransport", dependencies: ["UsageCore"]),
    .executableTarget(name: "QuotaPilotCLI", dependencies: ["UsageCore", "UsageTransport"]),
    .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore", "UsageTransport"])
]
#if os(macOS)
products.append(.executable(name: "QuotaPilot", targets: ["UsageWidget"]))
targets.append(.executableTarget(name: "UsageWidget", dependencies: ["UsageCore", "UsageTransport"]))
#endif

let package = Package(name: "QuotaPilot", platforms: [.macOS(.v13)], products: products, targets: targets)
