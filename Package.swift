// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "Size",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "sz", targets: ["Size"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2")
    ],
    targets: [
        .executableTarget(
            name: "Size",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "SizeTests",
            dependencies: ["Size"],
            path: "Tests"
        )
    ],
    swiftLanguageModes: [.v6]
)
