// swift-tools-version:6.2
//
// SignalCodecs: memory-safe, grammar-driven (LangSec) parsers and decoders for
// every untrusted media format SignalSafe handles. No Apple media frameworks.
//
// Rules for the library targets (enforced by Tools/lint-codecs.sh):
//   * no `import` of ImageIO, CoreGraphics, CoreImage, AVFoundation, VideoToolbox,
//     AudioToolbox, CoreMedia, Compression, AppKit, UIKit, or Foundation;
//   * no `Unsafe*` pointer APIs outside Sources/CodecCore/Unsafe/;
//   * raw byte access only through CodecCore's ByteCursor / ByteSlice / bit readers.
// The DifferentialTests target is the one exception: it may use Apple decoders as
// test oracles on trusted corpora. It is never linked into the app.

import PackageDescription

// Strict memory safety (SE-0458) on every target, as an error: any use of an
// unsafe construct must be spelled `unsafe` and is confined to CodecCore/Math/LibM.swift
// and the test oracles.
let memorySafety: [SwiftSetting] = [
    .strictMemorySafety(),
    .treatWarning("StrictMemorySafety", as: .error),
]

let strict: [SwiftSetting] = memorySafety + [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .unsafeFlags(["-warnings-as-errors"]),
    // Decoders run optimised in debug builds too (the UI snapshot tests decode large PNG
    // references); the checks under strict memory safety are the same at any -O level.
    .unsafeFlags(["-O"], .when(configuration: .debug)),
]

let package = Package(
    name: "SignalCodecs",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "CodecCore", targets: ["CodecCore"]),
        .library(name: "ImagePNG", targets: ["ImagePNG"]),
        .library(name: "ImageGIF", targets: ["ImageGIF"]),
        .library(name: "ImageBMP", targets: ["ImageBMP"]),
        .library(name: "Blurhash", targets: ["Blurhash"]),
        .library(name: "ImageJPEG", targets: ["ImageJPEG"]),
        .library(name: "EncodePNG", targets: ["EncodePNG"]),
        .library(name: "EncodeJPEG", targets: ["EncodeJPEG"]),
        .library(name: "EncodeWebP", targets: ["EncodeWebP"]),
        .library(name: "ImageWebP", targets: ["ImageWebP"]),
        .library(name: "HTMLMeta", targets: ["HTMLMeta"]),
        .library(name: "ContainerMP4", targets: ["ContainerMP4"]),
        .library(name: "AudioAAC", targets: ["AudioAAC"]),
        .library(name: "AudioMP3", targets: ["AudioMP3"]),
        .library(name: "VideoH264", targets: ["VideoH264"]),
        .library(name: "VideoHEVC", targets: ["VideoHEVC"]),
        .library(name: "MetadataStrip", targets: ["MetadataStrip"]),
    ],
    targets: [
        .target(name: "CodecCore", swiftSettings: strict),
        .target(name: "ImagePNG", dependencies: ["CodecCore"], swiftSettings: strict),
        .target(name: "ImageGIF", dependencies: ["CodecCore"], swiftSettings: strict),
        .target(name: "ImageBMP", dependencies: ["CodecCore", "ImagePNG"], swiftSettings: strict),
        .target(name: "Blurhash", dependencies: ["CodecCore"], swiftSettings: strict),
        .target(name: "ImageJPEG", dependencies: ["CodecCore"], swiftSettings: strict),
        .target(name: "EncodePNG", dependencies: ["CodecCore"], swiftSettings: strict),
        .target(name: "EncodeJPEG", dependencies: ["CodecCore"], swiftSettings: strict),
        .target(name: "EncodeWebP", dependencies: ["CodecCore"], swiftSettings: strict),
        .testTarget(name: "EncodeWebPTests", dependencies: ["EncodeWebP", "ImageWebP", "CodecCore"], swiftSettings: memorySafety),
        .target(name: "ImageWebP", dependencies: ["CodecCore"], exclude: ["LICENSE-libwebp.txt"], swiftSettings: strict),
        .target(name: "HTMLMeta", dependencies: ["CodecCore"], swiftSettings: strict),
        .target(name: "ContainerMP4", dependencies: ["CodecCore"], swiftSettings: strict),
        .target(name: "AudioAAC", dependencies: ["CodecCore"], swiftSettings: strict),
        .target(name: "AudioMP3", dependencies: ["CodecCore"], swiftSettings: strict),
        .target(name: "VideoH264", dependencies: ["CodecCore"], swiftSettings: strict),
        .target(name: "VideoHEVC", dependencies: ["CodecCore"], swiftSettings: strict),
        .target(name: "MetadataStrip", dependencies: ["CodecCore", "ImageJPEG"], swiftSettings: strict),
        .executableTarget(name: "codec-fuzz", dependencies: ["CodecCore", "ImagePNG", "ContainerMP4", "VideoH264", "AudioAAC", "AudioMP3"],
                          swiftSettings: memorySafety),

        .testTarget(name: "CodecCoreTests", dependencies: ["CodecCore"], swiftSettings: memorySafety),
        .testTarget(name: "AudioMP3Tests", dependencies: ["AudioMP3", "CodecCore"], swiftSettings: memorySafety),
        .testTarget(name: "VideoHEVCTests", dependencies: ["VideoHEVC", "ContainerMP4", "CodecCore"], resources: [.copy("Resources")],
                    swiftSettings: memorySafety),
        .testTarget(name: "MetadataStripTests", dependencies: ["MetadataStrip", "CodecCore", "ImageJPEG", "ImagePNG", "ImageWebP", "ImageGIF", "ContainerMP4", "VideoH264"],
                    resources: [.copy("Resources")], swiftSettings: memorySafety),
        .testTarget(name: "AudioAACTests", dependencies: ["AudioAAC", "CodecCore"], swiftSettings: memorySafety),
        .testTarget(name: "HTMLMetaTests", dependencies: ["HTMLMeta", "CodecCore"], swiftSettings: memorySafety),
        .testTarget(name: "ImagePNGTests", dependencies: ["ImagePNG", "CodecCore"], swiftSettings: memorySafety),
        .testTarget(
            name: "DifferentialTests",
            dependencies: ["CodecCore", "ImagePNG", "ImageGIF", "ImageBMP", "Blurhash", "ImageJPEG", "EncodePNG", "EncodeJPEG", "ImageWebP", "ContainerMP4", "AudioAAC", "AudioMP3", "VideoH264"],
            resources: [.copy("Resources")],
            swiftSettings: memorySafety
        ),
    ]
)
