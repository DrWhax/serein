// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "HTTPCheck", targets: [
    .systemLibrary(name: "CLibSoup", pkgConfig: "libsoup-3.0"),
    .target(name: "CLinuxHTTP", dependencies: ["CLibSoup"]),
    .executableTarget(name: "HTTPCheck", dependencies: ["CLinuxHTTP"], swiftSettings: [
        .strictMemorySafety(), .treatAllWarnings(as: .error), .enableExperimentalFeature("SafeInteropWrappers")
    ])
])
