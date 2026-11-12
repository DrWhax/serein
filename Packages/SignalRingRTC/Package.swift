// swift-tools-version:6.2
//
// SignalRingRTC: calling for SignalSafe (plan.md Phase 6). rust/ is our C ABI over ringrtc's
// native API (built as libsignal_ringrtc.dylib by Tools/build-ringrtc-ffi.sh).
//   * SignalRingRTC: the Swift API, a port of ringrtc's src/node/ringrtc/Service.ts (the layer
//     Signal Desktop calls), over an endpoint protocol (Endpoint.swift). Pure Swift, no
//     ringrtc: what the app links.
//   * RingRTCNative: the endpoint in this process, over the C ABI (integers, by-value structs
//     and annotated buffers, called through Span with no `unsafe`). The only target that links
//     the dylib: the calling service and tests.
//   * CallXPC: the endpoint in SignalCalling.xpc, as the app sees it (requests, frames, loss).
//   * CallService + SignalCallingService: that service, App Sandbox plus the Seatbelt rules of
//     Packages/SignalMediaService/Sandbox/SignalCalling.sb (network and microphone; no files).

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
        .library(name: "RingRTCNative", targets: ["RingRTCNative"]),
        .executable(name: "SignalCallingService", targets: ["SignalCallingService"]),
        .executable(name: "CallServiceCheck", targets: ["CallServiceCheck"]),
    ],
    dependencies: [.package(path: "../SignalMediaService")],
    targets: [
        // C header only (swiftSettings for the manifest lint; no Swift here).
        .target(name: "CSignalRingRTC", swiftSettings: memorySafety),
        .target(name: "SignalRingRTC", swiftSettings: strict),
        .target(
            name: "RingRTCNative",
            dependencies: ["CSignalRingRTC", "SignalRingRTC"],
            swiftSettings: strict,
            linkerSettings: [.unsafeFlags(["-L", dylibDir, "-lsignal_ringrtc", "-Xlinker", "-rpath", "-Xlinker", dylibDir])]
        ),
        .target(name: "CallXPC", dependencies: ["SignalRingRTC", .product(name: "MediaXPCInterface", package: "SignalMediaService")], swiftSettings: strict),
        .target(name: "CallService", dependencies: ["CallXPC", "RingRTCNative", .product(name: "MediaXPCInterface", package: "SignalMediaService")],
                swiftSettings: strict),
        .executableTarget(name: "SignalCallingService", dependencies: ["CallService", .product(name: "MediaXPCInterface", package: "SignalMediaService")],
                          swiftSettings: strict),
        // Tools/check-sandbox-profile.sh's host for the real service (not shipped).
        .executableTarget(name: "CallServiceCheck", dependencies: ["CallXPC", "SignalRingRTC", .product(name: "MediaXPCInterface", package: "SignalMediaService")],
                          swiftSettings: memorySafety),
        .testTarget(
            name: "SignalRingRTCTests",
            dependencies: ["SignalRingRTC", "RingRTCNative", "CallXPC", "CallService", .product(name: "MediaXPCInterface", package: "SignalMediaService")],
            swiftSettings: memorySafety
        ),
    ]
)
