// swift-tools-version:6.2
//
// SignalSafe.app: the macOS app target (AppKit lifecycle, one main window hosting SignalUI).
// Tools/build-app.sh wraps the executable into SignalSafe.app.

import PackageDescription

// The local RingRTC test peer (LocalCallTestPeer.swift and its hooks): debug builds and QA
// release builds only (`SEREIN_QA_CALL_PEER=1 Tools/build-app.sh` passes -DSEREIN_CALL_TEST_PEER).
let testPeer: [SwiftSetting] = [.define("SEREIN_CALL_TEST_PEER", .when(configuration: .debug))]

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
                // The client of SignalMessageParser.xpc (decrypted messages are parsed there).
                .product(name: "MessageParsing", package: "SignalCore"),
                .product(name: "SignalRingRTC", package: "SignalRingRTC"),
                // The Swift calling engine runs in SignalCalling.xpc.
                .product(name: "CallXPC", package: "SignalRingRTC"),
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
            ] + testPeer
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
            swiftSettings: [.strictMemorySafety(), .treatWarning("StrictMemorySafety", as: .error)] + testPeer
        ),
    ]
)

#if os(Linux)
package.targets.append(.systemLibrary(name: "CLinuxGIO", pkgConfig: "gio-2.0"))
package.targets.append(.target(name: "CLinuxDesktop", dependencies: ["CLinuxGIO", .product(name: "CLinuxLandlock", package: "SignalMediaService")],
                               linkerSettings: [.linkedLibrary("seccomp")]))
if let system = package.targets.first(where: { $0.name == "SignalSafeSystem" }) {
    system.dependencies += ["CLinuxDesktop", .product(name: "MediaXPCInterface", package: "SignalMediaService")]
    system.swiftSettings = (system.swiftSettings ?? []) + [.enableExperimentalFeature("SafeInteropWrappers")]
    system.exclude += ["AppSandbox.swift", "ContentProtection.swift", "LoginItem.swift", "PreventDisplaySleep.swift"]
}
package.dependencies.append(.package(path: "../../../QtSwiftUI"))
if let target = package.targets.first(where: { $0.name == "SignalSafe" }) {
    target.dependencies.append(.product(name: "SwiftUI", package: "QtSwiftUI"))
    target.exclude += ["main.swift", "AppDelegate.swift"]
}
#else
package.targets.first { $0.name == "SignalSafeSystem" }?.exclude.append("Linux")
package.targets.first { $0.name == "SignalSafe" }?.exclude.append("Linux")
#endif
