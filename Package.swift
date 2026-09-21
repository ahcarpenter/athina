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
        .target(
            name: "AthinaCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
            ]
        ),
        .executableTarget(
            name: "Athina",
            dependencies: ["AthinaCore"],
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
