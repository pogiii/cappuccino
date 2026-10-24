// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Cappuccino",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Cappuccino", targets: ["Cappuccino"])
    ],
    targets: [
        .executableTarget(name: "Cappuccino"),
        .testTarget(name: "CappuccinoTests", dependencies: ["Cappuccino"])
    ]
)
