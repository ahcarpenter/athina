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
    // Compares UI snapshot renders with the approved baselines (scripts/snapshots.sh, see
    // README "UI snapshot baselines").
    .executable(name: "snapshot-diff", targets: ["SnapshotDiffTool"]),
  ],
  traits: [
    // The end-to-end harness's in-app control API (README "The control
    // API"), off by default: scripts/bundle.sh turns it on for the
    // development bundle, and the release and App Store builds never do,
    // so their binaries carry none of it.
    .trait(
      name: "ControlAPI",
      description:
        """
        The in-app control API the end-to-end harness drives a replay through; development \
        builds only
        """
    ),
    // Builds the UI smoke test, the one target that uses
    // swift-snapshot-testing (README "UI snapshot smoke test"). It is off by
    // default, so the app, `make test` and every other build neither fetch
    // nor build it; `make test-snapshots-ci` turns it on.
    .trait(name: "UISnapshotsSmoke"),
  ],
  dependencies: [
    // Each pinned exactly, and no Package.resolved is committed, since a
    // committed one has every build fetch every package it names. Neither
    // depends on another package.
    //
    // The command lines of athina-drive and snapshot-diff, the developer
    // tools; the app and its release builds never link it.
    .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
    // Only for the UI smoke test, and fetched only with its trait on; the one
    // product used is SnapshotTesting.
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
    // AthinaCore and SnapshotDiff: a dependency or framework added here goes
    // there too, except the ControlAPI-conditional AthinaControl, which the
    // App Store build never carries.
    .executableTarget(
      name: "Athina",
      // SnapshotDiff so `--snapshot` judges two captures the same picture
      // by the rule the baseline comparison uses.
      dependencies: [
        "AthinaCore",
        "SnapshotDiff",
        .target(name: "AthinaControl", condition: .when(traits: ["ControlAPI"])),
      ],
      linkerSettings: [
        .linkedFramework("Carbon"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("Speech"),
      ]
    ),
    // What the control API's requests and answers are, shared by the app's
    // server and athina-drive's client.
    .target(name: "AthinaControlProtocol"),
    // The server itself, linked into the app only under the ControlAPI trait.
    // AthinaE2E for the harness's named journal queries, which it answers.
    .target(
      name: "AthinaControl",
      dependencies: ["AthinaCore", "AthinaControlProtocol", "AthinaE2E"],
      linkerSettings: [.linkedFramework("ApplicationServices")]
    ),
    .target(name: "AthinaE2E"),
    .executableTarget(
      name: "AthinaDrive",
      dependencies: [
        "AthinaE2E",
        "AthinaControlProtocol",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      linkerSettings: [.linkedFramework("ApplicationServices")]
    ),
    .target(name: "SnapshotDiff"),
    .executableTarget(
      name: "SnapshotDiffTool",
      dependencies: [
        "SnapshotDiff",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(name: "SnapshotDiffTests", dependencies: ["SnapshotDiff"]),
    // athina-drive's command line, parsed without touching the screen.
    .testTarget(name: "AthinaDriveTests", dependencies: ["AthinaDrive"]),
    .testTarget(
      // AthinaCore so the harness's journal queries are checked against a
      // journal the app itself just created, not a hand-written schema;
      // AthinaControlProtocol for the name a bundle with the control API carries.
      name: "AthinaE2ETests",
      dependencies: ["AthinaE2E", "AthinaCore", "AthinaControlProtocol"]
    ),
    .testTarget(
      name: "AthinaControlTests",
      dependencies: ["AthinaControl", "AthinaControlProtocol"]
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
          name: "SnapshotTesting",
          package: "swift-snapshot-testing",
          condition: .when(traits: ["UISnapshotsSmoke"])
        ),
      ],
      exclude: ["__Snapshots__"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
