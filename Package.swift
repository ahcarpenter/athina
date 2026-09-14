// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "mentor",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Mentor", targets: ["Mentor"]),
        .library(name: "MentorCore", targets: ["MentorCore"]),
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
        .testTarget(
            name: "MentorCoreTests",
            dependencies: ["MentorCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
