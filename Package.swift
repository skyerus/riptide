// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RiptideCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "RiptideCore", targets: ["RiptideCore"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.2"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0")
    ],
    targets: [
        .target(name: "RiptideCore", dependencies: [
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio")
        ]),
        .testTarget(name: "RiptideCoreTests", dependencies: ["RiptideCore"])
    ]
)
