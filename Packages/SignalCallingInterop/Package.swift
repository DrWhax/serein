// swift-tools-version:6.2
//
// Native RingRTC as an independent peer for interoperability tests.

import PackageDescription
let memorySafety: [SwiftSetting] = [.strictMemorySafety(), .treatWarning("StrictMemorySafety", as: .error)]
let strict: [SwiftSetting] = memorySafety + [.treatAllWarnings(as: .error), .enableExperimentalFeature("SafeInteropWrappers")]

let package = Package(
    name: "SignalCallingInterop",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "SignalCallTestPeerService", targets: ["SignalCallTestPeerService"]),
    ],
    dependencies: [.package(path: "../SignalRingRTC"), .package(path: "../SignalMediaService")],
    targets: [
        .executableTarget(name: "SignalCallTestPeerService", dependencies: [.product(name: "RingRTCNative", package: "SignalRingRTC"),
                          .product(name: "CallService", package: "SignalRingRTC"), .product(name: "SignalRingRTC", package: "SignalRingRTC"),
                          .product(name: "MediaXPCInterface", package: "SignalMediaService")], swiftSettings: strict),
    ]
)
