// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "athina",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Athina", targets: ["Athina"]),
        .library(name: "AthinaCore", targets: ["AthinaCore"]),
        // A product so project.yml's App Store target can link it, as the Athina target does.
        .library(name: "SnapshotDiff", targets: ["SnapshotDiff"]),
        // The end-to-end harness's drive tool (scripts/e2e, see README "End-to-end harness").
        .executable(name: "athina-drive", targets: ["AthinaDrive"]),
        // Compares UI snapshot renders with the approved baselines (scripts/snapshots.sh, see README "UI snapshot baselines").
        .executable(name: "snapshot-diff", targets: ["SnapshotDiffTool"]),
    ],
    traits: [
        // Builds the UI smoke test, the one target that uses
        // swift-snapshot-testing (README "UI snapshot smoke test"). It is off by
        // default, so the app, `make test` and every other build neither fetch
        // nor build it; `make ui-snapshots-smoke` turns it on.
        .trait(name: "UISnapshotsSmoke"),
    ],
    dependencies: [
        // Only for the UI smoke test, and fetched only with its trait on. Pinned
        // exactly, and no Package.resolved is committed, since a committed one
        // has every build fetch every package it names; the one product used,
        // SnapshotTesting, depends on no other package.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.6"),
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
                .linkedFramework("Speech"),
            ]
        ),
        // project.yml's App Store target compiles these same sources against
        // AthinaCore and SnapshotDiff: a dependency or framework added here goes there too.
        .executableTarget(
            name: "Athina",
            // SnapshotDiff so `--snapshot` judges two captures the same picture
            // by the rule the baseline comparison uses.
            dependencies: ["AthinaCore", "SnapshotDiff"],
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
        .target(name: "SnapshotDiff"),
        .executableTarget(name: "SnapshotDiffTool", dependencies: ["SnapshotDiff"]),
        .testTarget(name: "SnapshotDiffTests", dependencies: ["SnapshotDiff"]),
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
        .testTarget(
            // The app target itself, so the test draws the very views and
            // sample data `--snapshot` draws. Without the trait the target has
            // no dependencies and no tests, so `swift test` builds nothing of it.
            name: "UISnapshotsSmokeTests",
            dependencies: [
                .target(name: "Athina", condition: .when(traits: ["UISnapshotsSmoke"])),
                .product(
                    name: "SnapshotTesting", package: "swift-snapshot-testing",
                    condition: .when(traits: ["UISnapshotsSmoke"])
                ),
            ],
            exclude: ["__Snapshots__"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
