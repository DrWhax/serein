// swift-tools-version:6.2
//
// SignalCore: SignalSafe's protocol and data layer (Phase 2 of plan.md).
//   * LibSignalClient (vendor/libsignal, Swift bindings over the Rust FFI) for the
//     Signal Protocol, sealed sender, zkgroup and libsignal-net chat connections;
//   * GRDB on SQLCipher (vendor/GRDB.swift with Tools/vendor-patches/grdb-sqlcipher.patch);
//   * SwiftProtobuf code generated from Signal-Desktop/protos (Sources/SignalProtos);
//   * MessageParsing and SignalMessageParser.xpc: decrypted messages parsed in a keyless process.
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
// The local RingRTC test peer (Calling/LocalCallLinkTestPeer.swift): debug builds and QA release
// builds only (`SEREIN_QA_CALL_PEER=1 Tools/build-app.sh` passes -DSEREIN_CALL_TEST_PEER).
let testPeer: [SwiftSetting] = [.define("SEREIN_CALL_TEST_PEER", .when(configuration: .debug))]

let package = Package(
    name: "SignalCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SignalCore", targets: ["SignalCore"]),
        .library(name: "SignalProtos", targets: ["SignalProtos"]),
        .library(name: "MessageParsing", targets: ["MessageParsing"]),
        .executable(name: "SignalMessageParserService", targets: ["SignalMessageParserService"]),
        .executable(name: "SignalMessageParserChild", targets: ["SignalMessageParserChild"]),
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
        // The keyless structured-message parser: SignalMessageParser.xpc's child processes (one
        // per source) parse decrypted content, contact-sync records, sticker manifests and
        // link-and-sync backups (which they also inflate); SignalCore reads their trees back.
        .target(
            name: "MessageParsing",
            dependencies: ["SignalProtos", .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                           .product(name: "MediaXPCInterface", package: "SignalMediaService")],
            swiftSettings: strict
        ),
        // SignalMessageParser.xpc: no keys, no database, no network, no files (Sandbox/SignalMessageParser.sb).
        // It parses nothing itself: each session gets a SignalMessageParserChild process.
        .executableTarget(
            name: "SignalMessageParserService",
            dependencies: ["MessageParsing", .product(name: "MediaXPCInterface", package: "SignalMediaService")],
            swiftSettings: strict
        ),
        // One source's parser, in SignalMessageParser.xpc's bundle, under its sandbox.
        .executableTarget(
            name: "SignalMessageParserChild",
            dependencies: ["MessageParsing", .product(name: "MediaXPCInterface", package: "SignalMediaService"),
                           // gunzip for link-and-sync archives, here only (the app links no codec code).
                           .product(name: "CodecCore", package: "SignalCodecs")],
            swiftSettings: strict
        ),
        .target(
            name: "SignalCore",
            dependencies: [
                "SignalProtos",
                "MessageParsing",
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
            swiftSettings: strict + testPeer,
            linkerSettings: [.unsafeFlags(["-L", ffiDir])]
        ),
        .testTarget(
            name: "SignalCoreTests",
            dependencies: ["SignalCore", "SignalProtos", "MessageParsing", .product(name: "LibSignalClient", package: "libsignal"),
                           .product(name: "SignalRingRTC", package: "SignalRingRTC"),
                           .product(name: "RingRTCNative", package: "SignalRingRTC"),
                           .product(name: "MediaXPCInterface", package: "SignalMediaService"),
                           .product(name: "SignalMediaDecoder", package: "SignalMediaService"),
                           .product(name: "LinkPreviewFetcher", package: "SignalMediaService"),
                           .product(name: "WebFetch", package: "SignalMediaService"),
                           .product(name: "LinkPreviewParser", package: "SignalMediaService"),
                           .product(name: "EncodePNG", package: "SignalCodecs"), .product(name: "CodecCore", package: "SignalCodecs")],
            resources: [.copy("Resources")],
            swiftSettings: memorySafety + testPeer,
            linkerSettings: [.unsafeFlags(["-L", ffiDir])]
        ),
    ]
)
