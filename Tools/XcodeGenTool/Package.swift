// swift-tools-version: 6.2
import PackageDescription

// Pins XcodeGen, which generates Athina.xcodeproj from project.yml (README
// "The Xcode project"). A package of its own, never a dependency of the app's
// Package.swift, so `make build`, `make test` and CI's package jobs never fetch
// or build it; `make xcodeproj` runs it with
// `swift run --package-path Tools/XcodeGenTool xcodegen`. Package.resolved is
// committed, so every Mac and CI generate the project with the same version.
let package = Package(
    name: "XcodeGenTool",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/yonaskolb/XcodeGen.git", exact: "2.46.0"),
    ],
    targets: [
        // Only here so SwiftPM resolves and builds XcodeGen's executable, which
        // `swift run xcodegen` then runs; it has no code of its own.
        .target(name: "XcodeGenPin", dependencies: [.product(name: "xcodegen", package: "XcodeGen")]),
    ]
)
