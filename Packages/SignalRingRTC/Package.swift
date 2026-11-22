// swift-tools-version:6.2
//
// The app calls the SignalRingRTC Swift API through CallXPC. SignalCallingService hosts
// the Swift calling engine in the calling sandbox. CallService implements the shared XPC
// protocol, using the endpoint factory its executable supplies.
// RingRTCNative links the libsignal_ringrtc.dylib reference engine for interoperability
// tests and the optional SignalCallTestPeerService executable in Packages/SignalCallingInterop.

import Foundation
import PackageDescription

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let dylibDir = here + "/rust/target/aarch64-apple-darwin/release"

let memorySafety: [SwiftSetting] = [
    .strictMemorySafety(),
    .treatWarning("StrictMemorySafety", as: .error),
]
let strict: [SwiftSetting] = memorySafety + [.treatAllWarnings(as: .error), .enableExperimentalFeature("SafeInteropWrappers")]

let package = Package(
    name: "SignalRingRTC",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SignalRingRTC", targets: ["SignalRingRTC"]),
        .library(name: "CallXPC", targets: ["CallXPC"]),
        .library(name: "CallService", targets: ["CallService"]),
        .library(name: "RingRTCNative", targets: ["RingRTCNative"]),
        .executable(name: "SignalCallingService", targets: ["SignalCallingService"]),
        .executable(name: "CallServiceCheck", targets: ["CallServiceCheck"]),
    ],
    dependencies: [.package(path: "../SignalMediaService"), .package(path: "../SignalCodecs")],
    targets: [
        .target(name: "CallingWire", swiftSettings: strict),
        .target(name: "SignalRingRTC", dependencies: ["CallingWire"], swiftSettings: strict),
        .target(name: "SwiftCalling", dependencies: ["CallingWire",
            .product(name: "CodecCore", package: "SignalCodecs"), .product(name: "VideoVP8", package: "SignalCodecs"),
            .product(name: "VideoVP9", package: "SignalCodecs"),
        ], swiftSettings: strict),
        .target(name: "SwiftCallingServiceAdapter", dependencies: ["SignalRingRTC", "SwiftCalling"], swiftSettings: strict),
        // The tests and SignalCallingInterop link this adapter against the native reference.
        .target(name: "CSignalRingRTC", swiftSettings: memorySafety),
        .target(name: "RingRTCNative", dependencies: ["CSignalRingRTC", "SignalRingRTC"],
                swiftSettings: strict,
                linkerSettings: [.unsafeFlags(["-L", dylibDir, "-lsignal_ringrtc", "-Xlinker", "-rpath", "-Xlinker", dylibDir])]),
        .target(name: "CallXPC", dependencies: ["SignalRingRTC", .product(name: "MediaXPCInterface", package: "SignalMediaService")], swiftSettings: strict),
        .target(name: "CallService", dependencies: ["CallXPC", "SignalRingRTC", .product(name: "MediaXPCInterface", package: "SignalMediaService")],
                swiftSettings: strict),
        .executableTarget(name: "SignalCallingService", dependencies: ["CallService", "CallXPC", "SwiftCallingServiceAdapter",
                          .product(name: "MediaXPCInterface", package: "SignalMediaService")],
                          swiftSettings: strict),
        // Tools/check-sandbox-profile.sh's host for the real service (not shipped).
        .executableTarget(name: "CallServiceCheck", dependencies: ["CallXPC", "SignalRingRTC", .product(name: "MediaXPCInterface", package: "SignalMediaService")],
                          swiftSettings: strict),
        .testTarget(
            name: "SignalRingRTCTests",
            dependencies: ["SignalRingRTC", "SwiftCalling", "SwiftCallingServiceAdapter", "CallXPC", "CallService", "RingRTCNative",
                           .product(name: "MediaXPCInterface", package: "SignalMediaService"),
                           .product(name: "VideoVP9", package: "SignalCodecs")],
            swiftSettings: strict
        ),
    ]
)
