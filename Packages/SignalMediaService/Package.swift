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
        .library(name: "WebFetch", targets: ["WebFetch"]),
        .library(name: "LinkPreviewFetcher", targets: ["LinkPreviewFetcher"]),
        .executable(name: "SignalLinkPreviewFetcherService", targets: ["SignalLinkPreviewFetcherService"]),
        .library(name: "GifSearch", targets: ["GifSearch"]),
        .executable(name: "SignalGifSearchService", targets: ["SignalGifSearchService"]),
        .library(name: "VoiceNoteEncoder", targets: ["VoiceNoteEncoder"]),
        .library(name: "VoiceNoteService", targets: ["VoiceNoteService"]),
        .executable(name: "SignalVoiceNoteEncoderService", targets: ["SignalVoiceNoteEncoderService"]),
    ],
    dependencies: [.package(path: "../SignalCodecs"), .package(path: "../SignalText")],
    targets: [
        .target(name: "MediaXPCInterface", swiftSettings: strict),
        .target(
            name: "SignalMediaDecoder",
            dependencies: [
                "MediaXPCInterface",
                "VoiceNoteEncoder",
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
                .product(name: "ImageHEIF", package: "SignalCodecs"),
                .product(name: "MetadataStrip", package: "SignalCodecs"),
            ],
            swiftSettings: strict
        ),
        .executableTarget(name: "SignalMediaDecoderService", dependencies: ["SignalMediaDecoder"], swiftSettings: strict),
        // SignalVoiceNoteEncoder.xpc: the MP3 encoder for recorded voice notes, apart from every
        // decoder of received media (Sandbox/SignalVoiceNoteEncoder.sb).
        .target(name: "VoiceNoteEncoder", dependencies: ["MediaXPCInterface", .product(name: "AudioMP3", package: "SignalCodecs")], swiftSettings: strict),
        // The service's requests and the microphone recorder (AVFAudio), linked by the service only.
        .target(name: "VoiceNoteService", dependencies: ["VoiceNoteEncoder", "MediaXPCInterface"], swiftSettings: strict),
        .executableTarget(name: "SignalVoiceNoteEncoderService", dependencies: ["VoiceNoteService", "MediaXPCInterface"], swiftSettings: strict),
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
        // The web-facing services: HTTPS only, no parsers of media or HTML.
        .target(name: "WebFetch", swiftSettings: strict),
        // SignalLinkPreviewFetcher.xpc: fetches pages and images; HTML goes to the parser service.
        .target(name: "LinkPreviewFetcher", dependencies: ["MediaXPCInterface", "WebFetch", .product(name: "SignalText", package: "SignalText")],
                swiftSettings: strict),
        .executableTarget(name: "SignalLinkPreviewFetcherService", dependencies: ["LinkPreviewFetcher", "MediaXPCInterface", "WebFetch"], swiftSettings: strict),
        // SignalGifSearch.xpc: Giphy through Signal's content proxy (JSON decoded there).
        .target(name: "GifSearch", dependencies: ["MediaXPCInterface", "WebFetch"], swiftSettings: strict),
        .executableTarget(name: "SignalGifSearchService", dependencies: ["GifSearch", "MediaXPCInterface", "WebFetch"], swiftSettings: strict),
        .testTarget(name: "SignalMediaDecoderTests",
                    dependencies: ["SignalMediaDecoder", "MediaXPCInterface", "VoiceNoteEncoder", "VoiceNoteService", "LinkPreviewParser", "LinkPreviewFetcher", "GifSearch", "WebFetch",
                                   .product(name: "EncodePNG", package: "SignalCodecs"),
                                   .product(name: "ImagePNG", package: "SignalCodecs"),
                                   .product(name: "CodecCore", package: "SignalCodecs")],
                    resources: [.copy("Resources")],
                    swiftSettings: memorySafety),
    ]
)
