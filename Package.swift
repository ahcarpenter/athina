// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "mentor",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Mentor", targets: ["Mentor"]),
        .library(name: "MentorCore", targets: ["MentorCore"]),
        // The end-to-end harness's drive tool (scripts/e2e, see README "End-to-end harness").
        .executable(name: "mentor-drive", targets: ["MentorDrive"]),
    ],
    targets: [
        .target(
            name: "MentorCore",
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
            name: "Mentor",
            dependencies: ["MentorCore"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
            ]
        ),
        .target(name: "MentorE2E"),
        .executableTarget(
            name: "MentorDrive",
            dependencies: ["MentorE2E"],
            linkerSettings: [.linkedFramework("ApplicationServices")]
        ),
        .testTarget(
            name: "MentorE2ETests",
            dependencies: ["MentorE2E"]
        ),
        .testTarget(
            name: "MentorCoreTests",
            dependencies: ["MentorCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
