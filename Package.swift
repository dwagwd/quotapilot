// swift-tools-version: 5.9
import PackageDescription

// The core, transport and `quotapilot` command-line tool build on macOS, Linux and Windows.
// The menu bar app (AppKit, SwiftUI Charts) is macOS-only. Its product is QuotaPilotApp so it does not collide
// with the `quotapilot` CLI on case-insensitive file systems; build.sh installs it as QuotaPilot.app/…/QuotaPilot.
var products: [Product] = [.executable(name: "quotapilot", targets: ["QuotaPilotCLI"])]
var targets: [Target] = [
    .target(name: "UsageCore"),
    .target(name: "UsageTransport", dependencies: ["UsageCore"]),
    .executableTarget(name: "QuotaPilotCLI", dependencies: ["UsageCore", "UsageTransport"]),
    .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore", "UsageTransport"])
]
#if os(macOS)
products.append(.executable(name: "QuotaPilotApp", targets: ["UsageWidget"]))
targets.append(.executableTarget(name: "UsageWidget", dependencies: ["UsageCore", "UsageTransport"]))
#endif

let package = Package(name: "QuotaPilot", platforms: [.macOS(.v13)], products: products, targets: targets)
