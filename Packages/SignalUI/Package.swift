// swift-tools-version:6.2
//
// SignalUI: SwiftUI port of Signal Desktop's UI (plan.md Phase 3), one SwiftUI view per
// upstream component, named after it. Styling comes only from generated tokens
// (Tokens/*.generated.swift, Tools/gen-tokens.mjs) and the bundled fonts
// (Resources/Fonts, Tools/gen-fonts.sh).
//
// Tests render views and compare them with Storybook captures of the upstream
// components (Tools/capture-storybook.mjs) at ≤1% differing pixels.

import PackageDescription

let memorySafety: [SwiftSetting] = [
    .strictMemorySafety(),
    .treatWarning("StrictMemorySafety", as: .error),
]
let strict: [SwiftSetting] = memorySafety + [.treatAllWarnings(as: .error)]

let package = Package(
    name: "SignalUI",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SignalUI", targets: ["SignalUI"]),
    ],
    dependencies: [
        .package(path: "../SignalCodecs"),
        .package(path: "../SignalI18n"),
        .package(path: "../SignalText"),
    ],
    targets: [
        .target(
            name: "SignalUI",
            dependencies: [
                .product(name: "SignalI18n", package: "SignalI18n"),
                .product(name: "SignalText", package: "SignalText"),
                // Trusted bundled images only (Resources/Images); untrusted media is decoded in
                // the sandboxed SignalMediaDecoder service.
                .product(name: "ImagePNG", package: "SignalCodecs"),
                .product(name: "CodecCore", package: "SignalCodecs"),
                // Trusted constant blurhashes only (Attachment defaultBlurHash); a message's own
                // blurhash arrives decoded from the media service.
                .product(name: "Blurhash", package: "SignalCodecs"),
                // The media editor's export (pixels it drew itself; an encoder, not a parser).
                .product(name: "EncodeJPEG", package: "SignalCodecs"),
            ],
            resources: [.copy("Resources/Fonts"), .copy("Resources/Images"), .copy("Resources/country-display-names.json"), .copy("Resources/locale-display-names.json"), .copy("Resources/available-locales.json"), .copy("Resources/emoji-data.json")],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SignalUITests",
            dependencies: [
                "SignalUI",
                .product(name: "ImagePNG", package: "SignalCodecs"),
                .product(name: "ImageJPEG", package: "SignalCodecs"),
                .product(name: "ImageGIF", package: "SignalCodecs"),
                .product(name: "ImageWebP", package: "SignalCodecs"),
                .product(name: "ImageBMP", package: "SignalCodecs"),
                .product(name: "EncodePNG", package: "SignalCodecs"),
                .product(name: "CodecCore", package: "SignalCodecs"),
            ],
            resources: [.copy("References"), .copy("Fixtures")],
            // Snapshot pixel loops (RGBA conversion, PixelMatch) run optimised in debug too.
            swiftSettings: memorySafety + [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
    ]
)
