// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WispenCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WispenCore", targets: ["WispenCore"]),
    ],
    targets: [
        .target(name: "WispenCore", resources: [.copy("Resources/en_words.txt"), .copy("Resources/emoji.txt"), .copy("Resources/emoji_words.txt")]),
        .testTarget(name: "WispenCoreTests", dependencies: ["WispenCore"]),
    ]
)
