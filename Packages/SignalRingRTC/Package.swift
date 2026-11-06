// swift-tools-version:6.2
//
// SignalRingRTC: calling for SignalSafe (plan.md Phase 6). rust/ is our C ABI over ringrtc's
// native API (built as libsignal_ringrtc.dylib by Tools/build-ringrtc-ffi.sh); the Swift
// API (Sources/SignalRingRTC) is a port of ringrtc's src/node/ringrtc/Service.ts, the layer
// Signal Desktop calls. The C ABI takes only integers, by-value structs and annotated
// buffers, so the Swift side calls it through Span with no `unsafe`.

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
    ],
    targets: [
        // C header only (swiftSettings for the manifest lint; no Swift here).
        .target(name: "CSignalRingRTC", swiftSettings: memorySafety),
        .target(
            name: "SignalRingRTC",
            dependencies: ["CSignalRingRTC"],
            swiftSettings: strict,
            linkerSettings: [.unsafeFlags(["-L", dylibDir, "-lsignal_ringrtc", "-Xlinker", "-rpath", "-Xlinker", dylibDir])]
        ),
        .testTarget(
            name: "SignalRingRTCTests",
            dependencies: ["SignalRingRTC"],
            swiftSettings: memorySafety,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", dylibDir])]
        ),
    ]
)
