// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Passage",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PassageDesktop", targets: ["PassageApp"]),
        .executable(name: "passage", targets: ["PassageCLI"]),
        .executable(name: "passage-benchmark", targets: ["PassageBenchmark"]),
        .executable(
            name: "passage-segment-benchmark",
            targets: ["PassageSegmentBenchmark"]
        ),
        .executable(
            name: "passage-visual-benchmark",
            targets: ["PassageVisualBenchmark"]
        ),
        .executable(
            name: "passage-visual-smoke",
            targets: ["PassageVisualSmoke"]
        ),
        .library(name: "PassageCore", targets: ["PassageCore"]),
        .library(name: "PassageStore", targets: ["PassageStore"]),
        .library(name: "PassageCapture", targets: ["PassageCapture"]),
        .library(name: "PassageAgentSupport", targets: ["PassageAgentSupport"]),
        .library(name: "PassageService", targets: ["PassageService"]),
        .library(name: "PassageIntelligence", targets: ["PassageIntelligence"]),
        .library(
            name: "PassageVisualEvaluation",
            targets: ["PassageVisualEvaluation"]
        ),
        .library(name: "PassageVisualModel", targets: ["PassageVisualModel"]),
        .library(name: "PassageVisualSearch", targets: ["PassageVisualSearch"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.17.0"),
    ],
    targets: [
        .target(name: "PassageCore"),
        .target(
            name: "PassageStore",
            dependencies: [
                "PassageCore",
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
            ],
            cSettings: [
                .define("SQLITE_HAS_CODEC"),
            ]
        ),
        .target(
            name: "PassageCapture",
            dependencies: ["PassageCore", "PassageStore"]
        ),
        .target(name: "PassageAgentSupport"),
        .target(
            name: "PassageService",
            dependencies: ["PassageCore"]
        ),
        .target(
            name: "PassageIntelligence",
            dependencies: ["PassageCore", "PassageStore"]
        ),
        .target(name: "PassageVisualEvaluation"),
        .target(
            name: "PassageVisualModel",
            dependencies: ["PassageCore"]
        ),
        .target(
            name: "PassageVisualSearch",
            dependencies: [
                "PassageCore",
                "PassageStore",
                "PassageVisualModel",
            ]
        ),
        .target(
            name: "PassageUI",
            dependencies: [
                "PassageCore",
                "PassageStore",
                "PassageCapture",
                "PassageService",
                "PassageIntelligence",
                "PassageVisualModel",
                "PassageVisualSearch",
            ]
        ),
        .executableTarget(
            name: "PassageApp",
            dependencies: ["PassageUI"]
        ),
        .executableTarget(
            name: "PassageCLI",
            dependencies: ["PassageCore", "PassageService", "PassageAgentSupport"]
        ),
        .executableTarget(
            name: "PassageBenchmark",
            dependencies: ["PassageCore", "PassageStore"]
        ),
        .executableTarget(
            name: "PassageSegmentBenchmark",
            dependencies: ["PassageCore", "PassageStore"]
        ),
        .executableTarget(
            name: "PassageVisualBenchmark",
            dependencies: [
                "PassageCore",
                "PassageStore",
                "PassageVisualEvaluation",
            ]
        ),
        .executableTarget(
            name: "PassageVisualSmoke",
            dependencies: ["PassageVisualModel"]
        ),
        .testTarget(
            name: "PassageStoreTests",
            dependencies: ["PassageCore", "PassageStore"]
        ),
        .testTarget(
            name: "PassageCoreTests",
            dependencies: ["PassageCore"]
        ),
        .testTarget(
            name: "PassageCaptureTests",
            dependencies: ["PassageCore", "PassageCapture"]
        ),
        .testTarget(
            name: "PassageAgentSupportTests",
            dependencies: ["PassageAgentSupport"]
        ),
        .testTarget(
            name: "PassageServiceTests",
            dependencies: ["PassageCore", "PassageService"]
        ),
        .testTarget(
            name: "PassageIntelligenceTests",
            dependencies: ["PassageCore", "PassageStore", "PassageIntelligence"]
        ),
        .testTarget(
            name: "PassageUITests",
            dependencies: [
                "PassageCore",
                "PassageStore",
                "PassageService",
                "PassageIntelligence",
                "PassageVisualModel",
                "PassageVisualSearch",
                "PassageUI",
            ]
        ),
        .testTarget(
            name: "PassageVisualEvaluationTests",
            dependencies: ["PassageVisualEvaluation"]
        ),
        .testTarget(
            name: "PassageVisualModelTests",
            dependencies: ["PassageCore", "PassageVisualModel"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PassageVisualSearchTests",
            dependencies: [
                "PassageCore",
                "PassageStore",
                "PassageVisualModel",
                "PassageVisualSearch",
            ]
        ),
    ]
)
