// swift-tools-version:6.2
//
// SignalMediaService (plan.md, "all parsing of incoming media runs in a sandboxed XPC service"):
//   * MediaXPCInterface: the request/result types and the `MediaProcessing` protocol. The only
//     module of this package the app, SignalCore and SignalUI may import (no decoders).
//   * SignalMediaDecoder: the implementation over SignalCodecs, run inside the XPC service
//     (SignalMediaDecoder.xpc, no network or file entitlements) and in-process by tests only.
//   * LinkPreviewParser: link-preview HTML, run inside SignalLinkPreviewParser.xpc (App Sandbox
//     plus the Seatbelt rules in Sandbox/SignalLinkPreviewParser.sb) and in-process by tests.

import PackageDescription

let memorySafety: [SwiftSetting] = [
    .strictMemorySafety(),
    .treatWarning("StrictMemorySafety", as: .error),
]
let strict: [SwiftSetting] = memorySafety + [.treatAllWarnings(as: .error)]

let package = Package(
    name: "SignalMediaService",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "MediaXPCInterface", targets: ["MediaXPCInterface"]),
        .library(name: "SignalMediaDecoder", targets: ["SignalMediaDecoder"]),
        .executable(name: "SignalMediaDecoderService", targets: ["SignalMediaDecoderService"]),
        .library(name: "LinkPreviewParser", targets: ["LinkPreviewParser"]),
        .executable(name: "SignalLinkPreviewParserService", targets: ["SignalLinkPreviewParserService"]),
    ],
    dependencies: [.package(path: "../SignalCodecs")],
    targets: [
        .target(name: "MediaXPCInterface", swiftSettings: strict),
        .target(
            name: "SignalMediaDecoder",
            dependencies: [
                "MediaXPCInterface",
                .product(name: "CodecCore", package: "SignalCodecs"),
                .product(name: "ImagePNG", package: "SignalCodecs"),
                .product(name: "ImageJPEG", package: "SignalCodecs"),
                .product(name: "ImageGIF", package: "SignalCodecs"),
                .product(name: "ImageWebP", package: "SignalCodecs"),
                .product(name: "ImageBMP", package: "SignalCodecs"),
                .product(name: "Blurhash", package: "SignalCodecs"),
                .product(name: "EncodePNG", package: "SignalCodecs"),
                .product(name: "EncodeJPEG", package: "SignalCodecs"),
                .product(name: "EncodeWebP", package: "SignalCodecs"),
                .product(name: "ContainerMP4", package: "SignalCodecs"),
                .product(name: "AudioAAC", package: "SignalCodecs"),
                .product(name: "AudioMP3", package: "SignalCodecs"),
                .product(name: "VideoH264", package: "SignalCodecs"),
                .product(name: "VideoHEVC", package: "SignalCodecs"),
                .product(name: "MetadataStrip", package: "SignalCodecs"),
            ],
            swiftSettings: strict
        ),
        .executableTarget(name: "SignalMediaDecoderService", dependencies: ["SignalMediaDecoder"], swiftSettings: strict),
        // SignalLinkPreviewParser.xpc: link-preview HTML only (HTMLMeta), under its own tighter
        // Seatbelt profile (Sandbox/SignalLinkPreviewParser.sb). No image decoders.
        .target(
            name: "LinkPreviewParser",
            dependencies: [
                "MediaXPCInterface",
                .product(name: "CodecCore", package: "SignalCodecs"),
                .product(name: "HTMLMeta", package: "SignalCodecs"),
            ],
            swiftSettings: strict
        ),
        .executableTarget(name: "SignalLinkPreviewParserService", dependencies: ["LinkPreviewParser"], swiftSettings: strict),
        .testTarget(name: "SignalMediaDecoderTests",
                    dependencies: ["SignalMediaDecoder", "MediaXPCInterface", "LinkPreviewParser", .product(name: "EncodePNG", package: "SignalCodecs"),
                                   .product(name: "ImagePNG", package: "SignalCodecs"),
                                   .product(name: "CodecCore", package: "SignalCodecs")],
                    resources: [.copy("Resources")],
                    swiftSettings: memorySafety),
    ]
)
