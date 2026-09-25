import AppKit
import AthinaCore
import SwiftUI

@main
struct AthinaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let state = AppState.shared

    var body: some Scene {
        // A snapshot run renders the label itself, off screen, and puts no
        // item in the real menu bar.
        MenuBarExtra(isInserted: .constant(!Snapshots.isActive)) {
            MenuBarContent()
                .environment(state)
        } label: {
            MenuBarLabel(mark: state.menuBarMark, badge: state.clientModeBadge, statusLine: state.statusLine)
        }
        .menuBarExtraStyle(.menu)

        Window("Debug Panel", id: WindowID.debug) {
            DebugPanelView()
                .environment(state)
                .background(WindowFrameAutosave(name: "DebugPanel"))
        }
        // Tall enough for the Now pane's cards, Understanding included.
        .defaultSize(width: 1180, height: 860)
        // Opened, once the person turns it on in Settings > Advanced, from
        // that pane and from the menu's Debug Panel command, and at launch by
        // `--open debug` as `DebugPanelAccess` allows.
        .defaultLaunchBehavior(
            LaunchArguments.windowToOpen == WindowID.debug
                && DebugPanelAccess.opensAtLaunch(clientMode: state.clientMode, settings: state.settings)
                ? .presented : .suppressed
        )
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

/// The menu bar item: the variant of the mark for what Athina is doing. Every
/// variant is the same size, so the item keeps one width in every mode. While
/// calls are replayed or recorded, a word beside the mark says so, so a replay
/// is never mistaken for a live call.
struct MenuBarLabel: View {
    let mark: MenuBarMark
    let badge: String?
    let statusLine: String

    var body: some View {
        if let badge {
            HStack(spacing: 3) {
                MenuBarLabelImage(mark: mark)
                Text(badge)
            }
            .accessibilityLabel("Athina, \(badge), \(statusLine)")
        } else {
            MenuBarLabelImage(mark: mark)
                .accessibilityLabel("Athina, \(statusLine)")
        }
    }
}

/// The mark itself, at the size the menu bar draws it.
struct MenuBarLabelImage: View {
    let mark: MenuBarMark

    var body: some View {
        if let image = MenuBarMarkImage.image(for: mark) {
            Image(nsImage: image).renderingMode(.template)
        }
    }
}

/// Keeps a window's size and position across launches. SwiftUI saves no frame
/// for a window scene whose state restoration is off, which Athina's windows
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

/// Developer aids on the command line: `Athina --open debug|settings|permissions|history`
/// presents that window at launch, the debug panel on a live launch only while
/// Settings > Advanced turns it on (`DebugPanelAccess`) (for example
/// `open -n build/Athina.app --args --replay <dir> --open debug`; a plain `open`
/// brings an already running Athina forward and drops the arguments, and without
/// `--replay` the new instance is a second live Athina on the live journal, the
/// live settings and the same bill, which only `scripts/launch.sh` refuses),
/// `--open settings:models` opens Settings on that pane (`SettingsPane`), `--snapshot <dir>`
/// is handled by `Snapshots`, `--replay <dir>`, `--allow-stale-fixtures`, and
/// `--record [<dir>]` choose where model calls go (`ModelClientMode`), and
/// `--time-scale <n>` and `--advance-clock <interval>` set a replay's clock (`ClockMode`),
/// `--replay-latency immediate|recorded` sets how long a replayed call takes
/// (`ReplayLatencyMode`), and `--settings <path>` chooses the settings a replay
/// starts from (`LaunchFiles`).
/// Where a replay keeps its files is never an argument: it makes a directory of
/// its own and says which on the line it writes when it starts.
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
        // A launch that must not run says so and goes, rather than running
        // on something nobody asked for: a replay given a --settings file
        // that is not settings, or a live launch that could not move the
        // files the app kept as Mentor. A replay is started by a script, which
        // reads the line; a live launch may have come from Finder, where
        // nobody reads stderr, so it also says so on screen.
        if let refusal = AppState.shared.startupRefusal {
            FileHandle.standardError.write(Data(LaunchReport.didNotStart(refusal).line.utf8))
            AppState.log.error("did not start: \(refusal, privacy: .public)")
            if !AppState.shared.clientMode.isOffline {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
                alert.messageText = "Athina did not start"
                alert.informativeText = refusal
                alert.addButton(withTitle: "Quit")
                NSApp.activate()
                alert.runModal()
            }
            exit(2)
        }
        if let directory = Snapshots.requestedDirectory {
            // A sandboxed build writes only inside its container.
            if let refusal = RuntimeEnvironment.current.refusal(writing: directory, for: Snapshots.flag) {
                FileHandle.standardError.write(Data("snapshot failed: \(refusal)\n".utf8))
                exit(1)
            }
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
        // Past every reason this launch could refuse itself, and past `start`,
        // so a launcher waiting on this line knows the lane is up rather than
        // guessing from elapsed time: by now the clock channel is listening,
        // so a request sent the moment this is read is heard. A journal that
        // would not open is the one thing `start` finds out for itself, and it
        // leaves the lane unable to journal anything, so it is reported as the
        // failed launch it is. The app stays up either way, so the person at
        // the screen can read the error in the menu and the debug panel.
        let report = LaunchReport(
            pid: ProcessInfo.processInfo.processIdentifier,
            dataDirectory: AppState.shared.launchFiles.dataDirectory,
            journalError: AppState.shared.journalError
        )
        switch report {
        case .started:
            FileHandle.standardOutput.write(Data(report.line.utf8))
        case .didNotStart(let reason):
            FileHandle.standardError.write(Data(report.line.utf8))
            AppState.log.error("did not start: \(reason, privacy: .public)")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppState.shared.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The menu bar extra's menu: what Athina is doing, then its commands, then
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
        if let line = state.launchRefusalsLine {
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
        Button("Permissions…") { open(WindowID.permissions) }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        // A builder's tool, in a group of its own after the everyday windows,
        // as Safari's Develop menu follows its everyday menus, and only while
        // Settings > Advanced turns it on, in every mode.
        if state.settings.showDebugPanel {
            Divider()
            Button("Debug Panel") { open(WindowID.debug) }
        }
        Divider()
        // Athina has no app menu, so its menu carries the app menu's About and Quit.
        Button("About Athina") {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        Button("Quit Athina") { NSApp.terminate(nil) }
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
