// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ActivityTracker",
    platforms: [
        .macOS(.v13) // Ventura — ScreenCaptureKit, Vision, AX
    ],
    dependencies: [
        // SQLite via system module (built into macOS)
        // libpq via system module (built into macOS)
        // llama.cpp + whisper.cpp added as C targets when we reach those modules
    ],
    targets: [
        .executableTarget(
            name: "ActivityTracker",
            dependencies: [],
            path: "Sources",
            resources: [
                .copy("Resources/config.default.json")
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
