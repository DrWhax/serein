// swift-tools-version: 6.2
import PackageDescription

// The runner stages the production sources in Sources/ before building.
let package = Package(name: "KeyStoreCheck", targets: [
    .systemLibrary(name: "CLibSecret", pkgConfig: "libsecret-1"),
    .target(name: "CLinuxKeyStore", dependencies: ["CLibSecret"]),
    .executableTarget(name: "KeyStoreCheck", dependencies: ["CLinuxKeyStore"],
                      swiftSettings: [.strictMemorySafety(), .treatAllWarnings(as: .error), .enableExperimentalFeature("SafeInteropWrappers")])
])
