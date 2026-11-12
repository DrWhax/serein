// swift-tools-version:6.2
//
// SignalCore: SignalSafe's protocol and data layer (Phase 2 of plan.md).
//   * LibSignalClient (vendor/libsignal, Swift bindings over the Rust FFI) for the
//     Signal Protocol, sealed sender, zkgroup and libsignal-net chat connections;
//   * GRDB on SQLCipher (vendor/GRDB.swift with Tools/vendor-patches/grdb-sqlcipher.patch);
//   * SwiftProtobuf code generated from Signal-Desktop/protos (Sources/SignalProtos).
//
// Build prerequisites: Tools/apply-vendor-patches.sh, then
//   CARGO_BUILD_TARGET=aarch64-apple-darwin vendor/libsignal/swift/build_ffi.sh --release

import Foundation
import PackageDescription

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
let ffiDir = repoRoot + "/vendor/libsignal/target/aarch64-apple-darwin/release"

// Strict memory safety (SE-0458, `-strict-memory-safety`) on every target, as an error.
// Unavoidable unsafe calls (CommonCrypto, Security, C globals) are spelled `unsafe`
// and confined to Sources/SignalCore/Support/.
let memorySafety: [SwiftSetting] = [
    .strictMemorySafety(),
    .treatWarning("StrictMemorySafety", as: .error),
]
let strict: [SwiftSetting] = memorySafety + [.treatAllWarnings(as: .error)]

let package = Package(
    name: "SignalCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SignalCore", targets: ["SignalCore"]),
        .library(name: "SignalProtos", targets: ["SignalProtos"]),
    ],
    dependencies: [
        .package(path: "../../vendor/libsignal"),
        .package(path: "../../vendor/GRDB.swift"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.39.0"),
        .package(path: "../SignalMediaService"),
        .package(path: "../SignalCodecs"),
        .package(path: "../SignalText"),
        .package(path: "../SignalRingRTC"),
    ],
    targets: [
        .target(
            name: "SignalProtos",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            swiftSettings: [.swiftLanguageMode(.v5)] + memorySafety  // generated code
        ),
        .target(
            name: "SignalCore",
            dependencies: [
                "SignalProtos",
                .product(name: "LibSignalClient", package: "libsignal"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "SignalText", package: "SignalText"),
                // The media service's interface only: decoders never link into SignalCore.
                .product(name: "MediaXPCInterface", package: "SignalMediaService"),
                // Calling: RingRTC's Swift layer only. ringrtc itself runs in SignalCalling.xpc
                // (the app hands CallingService that endpoint; tests one in this process).
                .product(name: "SignalRingRTC", package: "SignalRingRTC"),
            ],
            swiftSettings: strict,
            linkerSettings: [.unsafeFlags(["-L", ffiDir])]
        ),
        .testTarget(
            name: "SignalCoreTests",
            dependencies: ["SignalCore", "SignalProtos", .product(name: "LibSignalClient", package: "libsignal"),
                           .product(name: "SignalRingRTC", package: "SignalRingRTC"),
                           .product(name: "RingRTCNative", package: "SignalRingRTC"),
                           .product(name: "MediaXPCInterface", package: "SignalMediaService"),
                           .product(name: "SignalMediaDecoder", package: "SignalMediaService"),
                           .product(name: "LinkPreviewFetcher", package: "SignalMediaService"),
                           .product(name: "WebFetch", package: "SignalMediaService"),
                           .product(name: "LinkPreviewParser", package: "SignalMediaService"),
                           .product(name: "EncodePNG", package: "SignalCodecs"), .product(name: "CodecCore", package: "SignalCodecs")],
            resources: [.copy("Resources")],
            swiftSettings: memorySafety,
            linkerSettings: [.unsafeFlags(["-L", ffiDir])]
        ),
    ]
)
