// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuadCastKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "QuadCastKit", targets: ["QuadCastKit"])
    ],
    targets: [
        .target(
            name: "CQuadCastUSB"
        ),
        .target(
            name: "QuadCastKit",
            dependencies: ["CQuadCastUSB"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "QuadCastKitTests",
            dependencies: ["QuadCastKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
