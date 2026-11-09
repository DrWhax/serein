// swift-tools-version:6.2
//
// SignalSafe.app: the macOS app target (AppKit lifecycle, one main window hosting SignalUI).
// Tools/build-app.sh wraps the executable into SignalSafe.app.

import PackageDescription

let package = Package(
    name: "SignalSafe",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(path: "../../Packages/SignalUI"),
        .package(path: "../../Packages/SignalI18n"),
        .package(path: "../../Packages/SignalCore"),
        .package(path: "../../Packages/SignalRingRTC"),
        .package(path: "../../Packages/SignalMediaService"),
        .package(path: "../../Packages/SignalText"),
        .package(path: "../../Packages/SignalCodecs"),
    ],
    targets: [
        .executableTarget(
            name: "SignalSafe",
            dependencies: [
                .product(name: "SignalUI", package: "SignalUI"),
                .product(name: "SignalI18n", package: "SignalI18n"),
                .product(name: "SignalCore", package: "SignalCore"),
                .product(name: "SignalRingRTC", package: "SignalRingRTC"),
                .product(name: "MediaXPCInterface", package: "SignalMediaService"),
                .product(name: "SignalText", package: "SignalText"),
                // Encoding our own drawings only (group avatars); decoders stay in the service.
                .product(name: "EncodePNG", package: "SignalCodecs"),
                .product(name: "CodecCore", package: "SignalCodecs"),
                "SignalSafeSystem",
            ],
            swiftSettings: [
                .strictMemorySafety(),
                .treatWarning("StrictMemorySafety", as: .error),
                .treatAllWarnings(as: .error),
            ]
        ),
        // macOS integration: display sleep during calls, screen security, login item,
        // system notifications.
        .target(
            name: "SignalSafeSystem",
            dependencies: [.product(name: "SignalCore", package: "SignalCore"), .product(name: "SignalI18n", package: "SignalI18n")],
            swiftSettings: [
                .strictMemorySafety(),
                .treatWarning("StrictMemorySafety", as: .error),
                .treatAllWarnings(as: .error),
            ]
        ),
        .testTarget(name: "SignalSafeSystemTests", dependencies: ["SignalSafeSystem"]),
        .testTarget(
            name: "SignalSafeTests",
            dependencies: ["SignalSafe", .product(name: "ImagePNG", package: "SignalCodecs"), .product(name: "CodecCore", package: "SignalCodecs"),
                           .product(name: "SignalUI", package: "SignalUI")],
            swiftSettings: [.strictMemorySafety(), .treatWarning("StrictMemorySafety", as: .error)]
        ),
    ]
)
