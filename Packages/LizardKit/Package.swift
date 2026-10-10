// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LizardKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "LizardCore", targets: ["LizardCore"]),
        .library(name: "Search", targets: ["Search"]),
        .library(name: "Notes", targets: ["Notes"]),
        .library(name: "Clipboard", targets: ["Clipboard"]),
        .library(name: "DevTools", targets: ["DevTools"]),
        .library(name: "Knowledge", targets: ["Knowledge"]),
        .library(name: "Screenshots", targets: ["Screenshots"]),
        .library(name: "AIEngine", targets: ["AIEngine"]),
        .library(name: "AIEngineMLX", targets: ["AIEngineMLX"]),
        .library(name: "ExtensionHost", targets: ["ExtensionHost"]),
        .executable(name: "lizardcli", targets: ["lizardcli"]),
    ],
    dependencies: [
        // Pinned for the Swift 6.2 toolchain (Xcode 26.2): mlx-swift >= 0.31.5 needs tools 6.3. Same pins as Cocoon.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(name: "LizardCore"),
        .target(name: "Search", dependencies: ["LizardCore"]),
        .target(name: "Notes", dependencies: ["LizardCore"]),
        .target(name: "Clipboard", dependencies: ["LizardCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "DevTools", dependencies: ["LizardCore"]),
        .target(name: "Knowledge", dependencies: ["LizardCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "Screenshots", dependencies: ["LizardCore"]),
        .target(name: "AIEngine"),
        .target(
            name: "AIEngineMLX",
            dependencies: [
                "AIEngine",
                "LizardCore",
                "Knowledge",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]),
        .target(
            name: "ExtensionHost",
            dependencies: ["LizardCore"],
            exclude: ["js"],
            linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(
            name: "lizardcli",
            dependencies: ["LizardCore", "Search", "Notes", "DevTools", "AIEngine", "ExtensionHost", "Knowledge"]),
        .testTarget(
            name: "LizardKitTests",
            dependencies: ["LizardCore", "Search", "Notes", "Clipboard", "DevTools", "AIEngine", "ExtensionHost", "Knowledge", "Screenshots"]),
    ],
    swiftLanguageModes: [.v6]
)
