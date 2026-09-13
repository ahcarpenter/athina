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
        .restorationBehavior(.disabled)

        Window("Mentor Permissions", id: WindowID.permissions) {
            PermissionsView()
                .environment(state)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(state.needsPermissionsOnboarding ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        Window("Mentor Settings", id: WindowID.settings) {
            SettingsView()
                .environment(state)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
    }
}

enum WindowID {
    static let debug = "debug"
    static let permissions = "permissions"
    static let settings = "settings"
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
