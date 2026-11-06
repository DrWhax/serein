// swift-tools-version:6.2
//
// SignalMediaService (plan.md, "all parsing of incoming media runs in a sandboxed XPC service"):
//   * MediaXPCInterface: the request/result types and the `MediaProcessing` protocol. The only
//     module of this package the app, SignalCore and SignalUI may import (no decoders).
//   * SignalMediaDecoder: the implementation over SignalCodecs, run inside the XPC service
//     (SignalMediaDecoder.xpc, no network or file entitlements) and in-process by tests only.

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
    ],
    dependencies: [.package(path: "../SignalCodecs")],
    targets: [
        .target(name: "MediaXPCInterface", swiftSettings: strict),
        .target(
            name: "SignalMediaDecoder",
            dependencies: [
                "MediaXPCInterface",
                .product(name: "CodecCore", package: "SignalCodecs"),
                .product(name: "HTMLMeta", package: "SignalCodecs"),
                .product(name: "ImagePNG", package: "SignalCodecs"),
                .product(name: "ImageJPEG", package: "SignalCodecs"),
                .product(name: "ImageGIF", package: "SignalCodecs"),
                .product(name: "ImageWebP", package: "SignalCodecs"),
                .product(name: "ImageBMP", package: "SignalCodecs"),
                .product(name: "Blurhash", package: "SignalCodecs"),
                .product(name: "EncodePNG", package: "SignalCodecs"),
                .product(name: "EncodeJPEG", package: "SignalCodecs"),
                .product(name: "ContainerMP4", package: "SignalCodecs"),
                .product(name: "AudioAAC", package: "SignalCodecs"),
                .product(name: "AudioMP3", package: "SignalCodecs"),
                .product(name: "VideoH264", package: "SignalCodecs"),
                .product(name: "MetadataStrip", package: "SignalCodecs"),
            ],
            swiftSettings: strict
        ),
        .testTarget(name: "SignalMediaDecoderTests",
                    dependencies: ["SignalMediaDecoder", "MediaXPCInterface", .product(name: "EncodePNG", package: "SignalCodecs"),
                                   .product(name: "ImagePNG", package: "SignalCodecs"),
                                   .product(name: "CodecCore", package: "SignalCodecs")],
                    resources: [.copy("Resources")],
                    swiftSettings: memorySafety),
    ]
)
