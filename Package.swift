// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "athina",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "Athina", targets: ["Athina"]),
    .library(name: "AthinaCore", targets: ["AthinaCore"]),
    // The end-to-end harness's drive tool (scripts/e2e, see docs/e2e.md).
    .executable(name: "athina-drive", targets: ["AthinaDrive"]),
    // Compares UI snapshot renders with the approved baselines (scripts/snapshots.sh, see
    // docs/ci.md "UI snapshot baselines").
    .executable(name: "snapshot-diff", targets: ["SnapshotDiffTool"]),
  ],
  traits: [
    // The end-to-end harness's in-app control API (docs/e2e.md "The control
    // API"), off by default: scripts/bundle.sh turns it on for the
    // development bundle, and the release build never does, so its binary
    // carries none of it.
    .trait(
      name: "ControlAPI",
      description:
        """
        The in-app control API the end-to-end harness drives a replay through; development \
        builds only
        """
    ),
    // Builds the UI smoke test, the one target that uses
    // swift-snapshot-testing (docs/ci.md "UI snapshot smoke test"). It is off by
    // default, so the app, `make test` and every other build neither fetch
    // nor build it; `make snapshots-smoke` and `make snapshots` turn it on.
    .trait(name: "UISnapshotsSmoke"),
    // Builds the API tier of the end-to-end harness, the one test target that
    // launches the app (docs/e2e.md). It is off by default, so
    // `make test` and plain `swift test` build and run none of it;
    // scripts/e2e/athina-e2e turns it on when it runs the API tier, having
    // built the app bundle the tests launch.
    .trait(name: "E2EAPI"),
  ],
  dependencies: [
    // Each pinned exactly, and no Package.resolved is committed, since a
    // committed one has every build fetch every package it names. None
    // depends on another package.
    //
    // The journal's SQLite access and its live queries (Journal.swift).
    .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    // The command lines of athina-drive and snapshot-diff, the developer
    // tools; the app and its release builds never link it.
    .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
    // The global keyboard shortcuts and their recorder, in the app itself
    // (docs/mentor-loop.md "Keyboard shortcuts").
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.1.0"),
    // Only for the UI smoke test, and fetched only with its trait on; the one
    // product used is SnapshotTesting.
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.6"),
  ],
  targets: [
    .target(
      name: "AthinaCore",
      // KeyboardShortcuts for the stored shortcut's own form of the combination.
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
      ],
      linkerSettings: [
        .linkedFramework("ScreenCaptureKit"),
        .linkedFramework("Vision"),
        .linkedFramework("ApplicationServices"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("Speech"),
      ]
    ),
    .executableTarget(
      name: "Athina",
      // SnapshotDiff so `--snapshot` judges two captures the same picture
      // by the rule the baseline comparison uses.
      dependencies: [
        "AthinaCore",
        "SnapshotDiff",
        .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
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
      // GRDB for the tests that write a journal as an older build left it.
      dependencies: [
        "AthinaCore",
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
      ],
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
    .testTarget(
      // The API tier of the end-to-end harness: each test a scenario that
      // launches a hermetic replay and drives it through the control API.
      // Without the trait its sources compile to nothing, so `swift test`
      // runs none of it.
      name: "E2EAPITests",
      dependencies: ["AthinaControlProtocol", "AthinaE2E"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
