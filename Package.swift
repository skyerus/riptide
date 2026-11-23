// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RiptideCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "RiptideCore", targets: ["RiptideCore"])],
    targets: [
        .target(name: "RiptideCore"),
        .testTarget(name: "RiptideCoreTests", dependencies: ["RiptideCore"])
    ]
)
