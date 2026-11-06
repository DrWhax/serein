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
    ],
    targets: [
        .executableTarget(
            name: "SignalSafe",
            dependencies: [
                .product(name: "SignalUI", package: "SignalUI"),
                .product(name: "SignalI18n", package: "SignalI18n"),
                .product(name: "SignalCore", package: "SignalCore"),
                .product(name: "SignalRingRTC", package: "SignalRingRTC"),
            ],
            swiftSettings: [
                .strictMemorySafety(),
                .treatWarning("StrictMemorySafety", as: .error),
                .treatAllWarnings(as: .error),
            ]
        ),
    ]
)
