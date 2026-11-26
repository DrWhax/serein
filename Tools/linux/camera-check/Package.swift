// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "CameraProbe", dependencies: [.package(path: "../../../Packages/SignalUI")], targets: [
    .target(name: "ProbeDesktop", linkerSettings: [.linkedLibrary("seccomp")]),
    .executableTarget(name: "CameraProbe", dependencies: ["SignalUI", "ProbeDesktop"], swiftSettings: [.strictMemorySafety(), .treatAllWarnings(as: .error)]),
])
