// swift-tools-version:6.2
//
// SignalText: text rules shared by SignalCore and SignalUI with no UI or protocol
// dependencies: link detection (linkify-it as Signal configures it) and the link-preview URL
// rules (ts/types/LinkPreview.std.ts).

import PackageDescription

let strict: [SwiftSetting] = [
    .strictMemorySafety(),
    .treatWarning("StrictMemorySafety", as: .error),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "SignalText",
    platforms: [.macOS("27.0")],
    products: [.library(name: "SignalText", targets: ["SignalText"])],
    targets: [
        .target(name: "SignalText", swiftSettings: strict),
    ]
)
