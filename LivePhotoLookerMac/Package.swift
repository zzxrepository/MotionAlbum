// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MotionAlbumMac",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MotionAlbum", targets: ["MotionAlbum"])
    ],
    targets: [
        .executableTarget(
            name: "MotionAlbum",
            path: "Sources/LivePhotoLooker",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
