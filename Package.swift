// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "athina",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Athina", targets: ["Athina"]),
        .library(name: "AthinaCore", targets: ["AthinaCore"]),
        // The end-to-end harness's drive tool (scripts/e2e, see README "End-to-end harness").
        .executable(name: "athina-drive", targets: ["AthinaDrive"]),
    ],
    targets: [
        // The one SQLite call Swift cannot make for itself (see the header).
        .target(name: "AthinaSQLiteShim", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(
            name: "AthinaCore",
            dependencies: ["AthinaSQLiteShim"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        // whisper.cpp, which runs both open speech models talking back can
        // download, OpenAI's Whisper and NVIDIA's Parakeet, on this Mac's GPU
        // (README "Talking back"). The project's own prebuilt framework for
        // the release, pinned by its SHA-256; no model comes with it.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip",
            checksum: "af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b"
        ),
        .executableTarget(
            name: "Athina",
            dependencies: ["AthinaCore", "whisper"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
            ]
        ),
        .target(name: "AthinaE2E"),
        .executableTarget(
            name: "AthinaDrive",
            dependencies: ["AthinaE2E"],
            linkerSettings: [.linkedFramework("ApplicationServices")]
        ),
        .testTarget(
            // AthinaCore so the harness's journal queries are checked against a
            // journal the app itself just created, not a hand-written schema.
            name: "AthinaE2ETests",
            dependencies: ["AthinaE2E", "AthinaCore"]
        ),
        .testTarget(
            name: "AthinaCoreTests",
            dependencies: ["AthinaCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
