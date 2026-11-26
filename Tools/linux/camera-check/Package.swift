// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "CameraProbe", dependencies: [.package(path: "../../../Packages/SignalUI")], targets: [
    .executableTarget(name: "CameraProbe", dependencies: ["SignalUI"], swiftSettings: [.strictMemorySafety(), .treatAllWarnings(as: .error)]),
])
