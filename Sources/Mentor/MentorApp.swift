import AppKit
import MentorCore
import SwiftUI

@main
struct MentorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(state)
        } label: {
            Image(systemName: state.menuBarSymbol)
                .accessibilityLabel(state.statusLine)
        }
        .menuBarExtraStyle(.menu)

        Window("Mentor Debug Panel", id: WindowID.debug) {
            DebugPanelView()
                .environment(state)
        }
        .defaultSize(width: 1180, height: 720)
        .defaultLaunchBehavior(LaunchArguments.windowToOpen == WindowID.debug ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        Window("Mentor Permissions", id: WindowID.permissions) {
            PermissionsView()
                .environment(state)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(!Snapshots.isActive && (state.needsPermissionsOnboarding || LaunchArguments.windowToOpen == WindowID.permissions) ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        Window("Mentor Settings", id: WindowID.settings) {
            SettingsView(initialTab: LaunchArguments.settingsTab)
                .environment(state)
        }
        .defaultSize(width: 600, height: 560)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(LaunchArguments.windowToOpen == WindowID.settings ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        Window("Mentor Suggestions", id: WindowID.history) {
            HistoryView()
                .environment(state)
        }
        .defaultSize(width: 860, height: 520)
        .defaultLaunchBehavior(LaunchArguments.windowToOpen == WindowID.history ? .presented : .suppressed)
        .restorationBehavior(.disabled)
    }
}

enum WindowID {
    static let debug = "debug"
    static let permissions = "permissions"
    static let settings = "settings"
    static let history = "history"
}

/// Developer aids on the command line: `Mentor --open debug|settings|permissions|history`
/// presents that window at launch (for example `open build/Mentor.app --args --open debug`),
/// `--open settings:mentor` opens Settings on that tab, and `--snapshot <dir>` is handled
/// by `Snapshots`.
enum LaunchArguments {
    private static var openArgument: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--open"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static var windowToOpen: String? {
        openArgument.map { String($0.split(separator: ":", maxSplits: 1)[0]) }
    }

    static var settingsTab: SettingsView.Tab {
        guard let argument = openArgument, argument.hasPrefix("settings:") else { return .mentor }
        switch argument.dropFirst("settings:".count) {
        case "frames": return .frames
        case "journal": return .journal
        case "privacy": return .privacy
        case "cadence": return .cadence
        default: return .mentor
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let directory = Snapshots.requestedDirectory {
            Task { @MainActor in
                do {
                    try await Snapshots.render(to: directory)
                    print("snapshots written to \(directory.path)")
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                    exit(1)
                }
            }
            return
        }
        AppState.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppState.shared.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MenuBarContent: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(state.statusLine)
        Text(state.mentorLine)
        if let context = state.mentorContextLine {
            Text(context)
        }
        if let resources = state.resources {
            Text(String(format: "%.1f%% CPU · %@", resources.cpuPercent, Formatting.bytes(resources.footprintBytes)))
        }
        Divider()
        Button(state.isPaused ? "Resume Watching" : "Pause Watching") {
            state.togglePause()
        }
        .optionalKeyboardShortcut(Formatting.keyboardShortcut(for: state.settings.pauseHotKey))
        Button("Capture Now") {
            state.captureNow()
        }
        .disabled(!state.mode.capturesFrames)
        Divider()
        Button("Show Last Suggestion") { state.showLastSuggestion() }
            .disabled(state.suggestionHistory.isEmpty)
        Button("Suggestions…") { open(WindowID.history) }
            .keyboardShortcut("h")
        Button("Debug Panel…") { open(WindowID.debug) }
            .keyboardShortcut("d")
        Button("Permissions…") { open(WindowID.permissions) }
        Button("Settings…") { open(WindowID.settings) }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Mentor") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ id: String) {
        NSApp.activate()
        openWindow(id: id)
    }
}
