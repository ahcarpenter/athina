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
            ]
        ),
        .executableTarget(
            name: "Mentor",
            dependencies: ["MentorCore"],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(
            name: "MentorCoreTests",
            dependencies: ["MentorCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
