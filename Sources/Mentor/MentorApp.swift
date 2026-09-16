import AppKit
import MentorCore
import SwiftUI

@main
struct MentorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let state = AppState.shared

    var body: some Scene {
        // A snapshot run renders the label itself, off screen, and puts no
        // item in the real menu bar.
        MenuBarExtra(isInserted: .constant(!Snapshots.isActive)) {
            MenuBarContent()
                .environment(state)
        } label: {
            MenuBarLabel(mode: state.mode, badge: state.clientModeBadge, statusLine: state.statusLine)
        }
        .menuBarExtraStyle(.menu)

        Window("Debug Panel", id: WindowID.debug) {
            DebugPanelView()
                .environment(state)
                .background(WindowFrameAutosave(name: "DebugPanel"))
        }
        // Tall enough for the Now pane's cards, Understanding included.
        .defaultSize(width: 1180, height: 860)
        .defaultLaunchBehavior(LaunchArguments.windowToOpen == WindowID.debug ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        Window("Permissions", id: WindowID.permissions) {
            PermissionsView()
                .environment(state)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(!Snapshots.isActive && (state.needsPermissionsOnboarding || LaunchArguments.windowToOpen == WindowID.permissions) ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        Window("Suggestions", id: WindowID.history) {
            HistoryView()
                .environment(state)
                .background(WindowFrameAutosave(name: "Suggestions"))
        }
        .defaultSize(width: 860, height: 520)
        .defaultLaunchBehavior(LaunchArguments.windowToOpen == WindowID.history ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(state)
        }
        .defaultLaunchBehavior(LaunchArguments.windowToOpen == WindowID.settings ? .presented : .suppressed)
        .restorationBehavior(.disabled)
    }
}

/// The menu bar item: the sensing mode's symbol in a fixed-width template
/// image (`MenuBarIcon`), so the item keeps one width in every mode. While
/// calls are replayed or recorded, a word beside the icon says so, so a replay
/// is never mistaken for a live call.
struct MenuBarLabel: View {
    let mode: SensingMode
    let badge: String?
    let statusLine: String

    var body: some View {
        if let badge {
            HStack(spacing: 3) {
                icon
                Text(badge)
            }
            .accessibilityLabel("Mentor, \(badge), \(statusLine)")
        } else {
            icon
                .accessibilityLabel("Mentor, \(statusLine)")
        }
    }

    private var icon: Image {
        Image(nsImage: MenuBarIcon.image(for: mode))
    }
}

/// Keeps a window's size and position across launches. SwiftUI saves no frame
/// for a window scene whose state restoration is off, which Mentor's windows
/// need so they do not reopen at every login.
struct WindowFrameAutosave: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        AutosaveView(name: name)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AutosaveView: NSView {
        let name: String

        init(name: String) {
            self.name = name
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.frameAutosaveName != name else { return }
            window.setFrameUsingName(name)
            window.setFrameAutosaveName(name)
        }
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
/// `--open settings:models` opens Settings on that pane (`SettingsPane`), `--snapshot <dir>`
/// is handled by `Snapshots`, `--replay <dir>`, `--allow-stale-fixtures`, and
/// `--record [<dir>]` choose where model calls go (`ModelClientMode`), and
/// `--time-scale <n>` and `--advance-clock <interval>` set a replay's clock (`ClockMode`).
enum LaunchArguments {
    private static var openArgument: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--open"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static var windowToOpen: String? {
        openArgument.map { String($0.split(separator: ":", maxSplits: 1)[0]) }
    }

    /// The Settings pane `--open settings:<pane>` names, if any.
    static var settingsPane: SettingsPane? {
        guard let argument = openArgument, argument.hasPrefix("settings:") else { return nil }
        return SettingsPane(rawValue: String(argument.dropFirst("settings:".count)))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Chosen before any scene is built, so the Settings window opens on it.
        LaunchArguments.settingsPane?.select()
    }

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

/// The menu bar extra's menu: what Mentor is doing, then its commands, then
/// its windows, then Quit. Status rows are dimmed text; a status that needs
/// something from the person is a command that goes there.
struct MenuBarContent: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(state.statusLine)
        if let line = state.clientModeLine {
            Text(line)
        }
        if let line = state.clockLine {
            Text(line)
        }
        if let action = state.menuStatusAction {
            Button(action.title) { perform(action) }
        } else {
            Text(state.mentorLine)
        }
        if let context = state.mentorContextLine {
            Text(context)
        }
        if let understandingLine = state.understandingLine {
            Text(understandingLine)
        }
        if let action = state.talkBackAction {
            Button(action.title) { perform(action) }
        } else {
            Text(state.talkBackLine)
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
            .disabled(state.lastShownSuggestion == nil)
        // The suggestion never takes keyboard focus, so its answers are here
        // too, where the keyboard and VoiceOver reach them. The submenu stays
        // in the menu, its items dimmed, while no suggestion is up.
        Menu("Answer Suggestion") {
            Group {
                Button("Tell Me More") { state.answerActiveSuggestion(.tellMeMore) }
                Button("Not Now") { state.answerActiveSuggestion(.notNow) }
                Button("Never for This") { state.answerActiveSuggestion(.never) }
                Divider()
                Button("Close Suggestion") { state.answerActiveSuggestion(.dismissed) }
            }
            .disabled(state.activeSuggestion == nil)
        }
        Divider()
        Button("Suggestions") { open(WindowID.history) }
        Button("Debug Panel") { open(WindowID.debug) }
        Button("Permissions…") { open(WindowID.permissions) }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        // Mentor has no app menu, so its menu carries the app menu's About and Quit.
        Button("About Mentor") {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        Button("Quit Mentor") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ id: String) {
        NSApp.activate()
        openWindow(id: id)
    }

    private func perform(_ action: MenuStatusAction) {
        switch action.destination {
        case .settings(let pane):
            pane.select()
            NSApp.activate()
            openSettings()
        case .permissions:
            open(WindowID.permissions)
        }
    }
}

/// A menu status that asks for something, shown as the command that does it.
struct MenuStatusAction: Equatable {
    enum Destination: Equatable {
        case settings(SettingsPane)
        case permissions
    }

    var title: String
    var destination: Destination
}
