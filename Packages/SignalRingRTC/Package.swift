// swift-tools-version:6.2
//
// The app calls the SignalRingRTC Swift API through CallXPC. SignalCallingService hosts
// the Swift calling engine in the calling sandbox. CallService implements the shared XPC
// protocol, using the endpoint factory its executable supplies.
// RingRTCNative links the libsignal_ringrtc.dylib reference engine for interoperability
// tests and the optional SignalCallTestPeerService executable in Packages/SignalCallingInterop.

import Foundation
import PackageDescription

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let dylibDir = here + "/rust/target/aarch64-apple-darwin/release"

let memorySafety: [SwiftSetting] = [
    .strictMemorySafety(),
    .treatWarning("StrictMemorySafety", as: .error),
]
// The local RingRTC test peer (CallXPC/CallTestPeer.swift, GroupCall+LocalMediaKey.swift) is
// compiled into debug builds and QA release builds only: `SEREIN_QA_CALL_PEER=1 Tools/build-app.sh`
// passes -DSEREIN_CALL_TEST_PEER. A shipping release build contains none of it.
let testPeer: [SwiftSetting] = [.define("SEREIN_CALL_TEST_PEER", .when(configuration: .debug))]
let strict: [SwiftSetting] = memorySafety + [.treatAllWarnings(as: .error), .enableExperimentalFeature("SafeInteropWrappers")] + testPeer

let package = Package(
    name: "SignalRingRTC",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SignalRingRTC", targets: ["SignalRingRTC"]),
        .library(name: "CallXPC", targets: ["CallXPC"]),
        .library(name: "CallService", targets: ["CallService"]),
        .library(name: "RingRTCNative", targets: ["RingRTCNative"]),
        .executable(name: "SignalCallingService", targets: ["SignalCallingService"]),
        .executable(name: "CallServiceCheck", targets: ["CallServiceCheck"]),
    ],
    dependencies: [.package(path: "../SignalMediaService"), .package(path: "../SignalCodecs")],
    targets: [
        .target(name: "CallingWire", swiftSettings: strict),
        .target(name: "SignalRingRTC", dependencies: ["CallingWire"], swiftSettings: strict),
        .target(name: "SwiftCalling", dependencies: ["CallingWire",
            .product(name: "CodecCore", package: "SignalCodecs"), .product(name: "VideoVP8", package: "SignalCodecs"),
            .product(name: "VideoVP9", package: "SignalCodecs"),
        ], swiftSettings: strict),
        .target(name: "SwiftCallingServiceAdapter", dependencies: ["SignalRingRTC", "SwiftCalling"], swiftSettings: strict),
        // The tests and SignalCallingInterop link this adapter against the native reference.
        .target(name: "CSignalRingRTC", swiftSettings: memorySafety),
        .target(name: "RingRTCNative", dependencies: ["CSignalRingRTC", "SignalRingRTC"],
                swiftSettings: strict,
                linkerSettings: [.unsafeFlags(["-L", dylibDir, "-lsignal_ringrtc", "-Xlinker", "-rpath", "-Xlinker", dylibDir])]),
        .target(name: "CallXPC", dependencies: ["SignalRingRTC", .product(name: "MediaXPCInterface", package: "SignalMediaService")], swiftSettings: strict),
        .target(name: "CallService", dependencies: ["CallXPC", "SignalRingRTC", .product(name: "MediaXPCInterface", package: "SignalMediaService")],
                swiftSettings: strict),
        .executableTarget(name: "SignalCallingService", dependencies: ["CallService", "CallXPC", "SwiftCallingServiceAdapter",
                          .product(name: "MediaXPCInterface", package: "SignalMediaService")],
                          swiftSettings: strict),
        // Tools/check-sandbox-profile.sh's host for the real service (not shipped).
        .executableTarget(name: "CallServiceCheck", dependencies: ["CallXPC", "SignalRingRTC", .product(name: "MediaXPCInterface", package: "SignalMediaService")],
                          swiftSettings: strict),
        .testTarget(
            name: "SignalRingRTCTests",
            dependencies: ["SignalRingRTC", "SwiftCalling", "SwiftCallingServiceAdapter", "CallXPC", "CallService", "RingRTCNative",
                           .product(name: "MediaXPCInterface", package: "SignalMediaService"),
                           .product(name: "VideoVP9", package: "SignalCodecs")],
            swiftSettings: strict
        ),
    ]
)

#if os(Linux)
// Map imports in these consumers only. Crypto itself builds its normal Linux implementation.
package.dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", exact: "5.1.1"))
let cryptoConsumers: Set<String> = ["SignalRingRTC", "SwiftCalling", "SwiftCallingServiceAdapter", "SignalRingRTCTests"]
for target in package.targets where cryptoConsumers.contains(target.name) {
    target.dependencies.append(.product(name: "Crypto", package: "swift-crypto"))
    target.swiftSettings?.append(.unsafeFlags(["-module-alias", "CryptoKit=Crypto"]))
}
#endif

#if os(Linux)
package.targets.append(.systemLibrary(name: "CCallGIO", pkgConfig: "gio-2.0"))
package.targets.append(.target(name: "CLinuxCallNetwork", dependencies: ["CCallGIO"]))
package.targets.append(.target(name: "CLinuxCallAudio", linkerSettings: [.linkedLibrary("asound")]))
package.targets.first { $0.name == "SignalCallingService" }?.dependencies.append("CLinuxCallNetwork")
if let calling = package.targets.first(where: { $0.name == "SwiftCalling" }) {
    calling.dependencies += ["CLinuxCallAudio", "CLinuxCallNetwork", .product(name: "CryptoExtras", package: "swift-crypto")]
    calling.exclude += ["CallSpeaker.swift", "CallMicrophone.swift", "EngineMicrophone.swift", "TURNConnection.swift"]
}
#else
package.targets.first { $0.name == "SwiftCalling" }?.exclude.append("Linux")
#endif
