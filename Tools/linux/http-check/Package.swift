// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "HTTPCheck", targets: [
    .systemLibrary(name: "CLibSoup", pkgConfig: "libsoup-3.0"),
    .target(name: "CLinuxHTTP", dependencies: ["CLibSoup"]),
    .target(name: "LinuxHTTP", dependencies: ["CLinuxHTTP"], swiftSettings: [.enableExperimentalFeature("SafeInteropWrappers")]),
    .target(name: "WebFetch", dependencies: ["LinuxHTTP", "CLinuxHTTP"], swiftSettings: [.enableExperimentalFeature("SafeInteropWrappers")]),
    .testTarget(name: "DestinationPolicyTests", dependencies: ["WebFetch"]),
    .executableTarget(name: "HTTPCheck", dependencies: ["LinuxHTTP", "WebFetch"], swiftSettings: [
        .strictMemorySafety(), .treatAllWarnings(as: .error), .enableExperimentalFeature("SafeInteropWrappers")
    ])
])
