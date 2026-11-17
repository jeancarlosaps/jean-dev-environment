// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Shop",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "Shop", targets: ["Shop"])],
    targets: [
        .target(name: "Shop"),
        .testTarget(name: "ShopTests", dependencies: ["Shop"])
    ]
)
