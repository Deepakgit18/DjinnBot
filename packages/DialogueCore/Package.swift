// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DialogueCore",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(
            name: "DialogueCore",
            targets: ["DialogueCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.1"),
        .package(url: "https://github.com/sbooth/SFBAudioEngine.git", from: "0.12.1"),
        .package(url: "https://github.com/ordo-one/FuzzyMatch.git", from: "1.2.2"),
    ],
    targets: [
        .target(
            name: "DialogueCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
                .product(name: "FuzzyMatch", package: "FuzzyMatch"),
            ]
        ),
    ]
)
