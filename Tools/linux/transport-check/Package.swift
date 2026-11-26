// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TransportCheck",
    dependencies: [.package(path: "../../../Packages/SignalMediaService")],
    targets: [.executableTarget(name: "TransportCheck", dependencies: [
        .product(name: "MediaXPCInterface", package: "SignalMediaService")
    ])]
)
