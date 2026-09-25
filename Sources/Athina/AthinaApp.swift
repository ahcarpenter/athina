import AppKit
import AthinaCore
import Foundation
import SwiftUI

#if ControlAPI
  import AthinaControl
#endif

@main
struct AthinaApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self)
  private var delegate

  @Environment(\.openWindow)
  private var openWindow

  @Environment(\.openSettings)
  private var openSettings

  private let state = AppState.shared

  var body: some Scene {
    // The app's own actions, so the menu's commands open windows with no
    // menu bar extra up, as in a hermetic run.
    let _ = state.windows.connect(openWindow: openWindow, openSettings: openSettings)
    // A snapshot run renders the label itself, off screen, and a hermetic
    // run keeps out of the menu bar every other app shares; neither puts an
    // item there.
    MenuBarExtra(
      isInserted: .constant(!Snapshots.isActive && !state.controlMode.isHermetic),
      content: {
        MenuBarContent()
          .environment(state)
      },
      label: {
        MenuBarLabel(
          mark: state.menuBarMark,
          badge: state.clientModeBadge,
          statusLine: state.statusLine
        )
      }
    )
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
    .defaultLaunchBehavior(
      !Snapshots.isActive
        && (state.needsPermissionsOnboarding
          || LaunchArguments.windowToOpen == WindowID.permissions)
        ? .presented : .suppressed
    )
    .restorationBehavior(.disabled)

    Window("Suggestions", id: WindowID.history) {
      HistoryView()
        .environment(state)
        .background(WindowFrameAutosave(name: "Suggestions"))
    }
    .defaultSize(width: 860, height: 520)
    .defaultLaunchBehavior(
      LaunchArguments.windowToOpen == WindowID.history ? .presented : .suppressed
    )
    .restorationBehavior(.disabled)

    Settings {
      SettingsView()
        .environment(state)
    }
    .defaultLaunchBehavior(
      LaunchArguments.windowToOpen == WindowID.settings ? .presented : .suppressed
    )
    .restorationBehavior(.disabled)
  }
}

/// The menu bar item: the variant of the mark for what Athina is doing.
///
/// Every variant is the same size, so the item keeps one width in every mode.
/// While calls are replayed or recorded, a word beside the mark says so, so a
/// replay is never mistaken for a live call.
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

/// Keeps a window's size and position across launches.
///
/// SwiftUI saves no frame for a window scene whose state restoration is off,
/// which Athina's windows need so they do not reopen at every login.
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

/// Opens Athina's windows from code outside any view, with the actions the
/// app itself has (`AthinaApp` connects them): the menu's commands run here,
/// including in a hermetic run, which has no menu bar extra to run them from.
@MainActor
final class WindowOpener {
  private var openWindow: OpenWindowAction?
  private var openSettingsAction: OpenSettingsAction?

  func connect(openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
    self.openWindow = openWindow
    openSettingsAction = openSettings
  }

  func open(_ id: String) {
    AppActivation.request()
    openWindow?(id: id)
  }

  func openSettings() {
    AppActivation.request()
    openSettingsAction?()
  }
}

/// Developer aids on the command line.
///
/// `Athina --open debug|settings|permissions|history` presents that window at
/// launch, the debug panel on a live launch only while Settings > Advanced
/// turns it on (`DebugPanelAccess`) (for example
/// `open -n build/Athina.app --args --replay <dir> --open debug`; a plain
/// `open` brings an already running Athina forward and drops the arguments,
/// and without `--replay` the new instance is a second live Athina on the live
/// journal, the live settings and the same bill, which only `scripts/launch.sh`
/// refuses), `--open settings:models` opens Settings on that pane
/// (`SettingsPane`), `--snapshot <dir>` is handled by `Snapshots`,
/// `--replay <dir>`, `--allow-stale-fixtures`, and `--record [<dir>]` choose
/// where model calls go (`ModelClientMode`), and `--time-scale <n>` and
/// `--advance-clock <interval>` set a replay's clock (`ClockMode`),
/// `--replay-latency immediate|recorded` sets how long a replayed call takes
/// (`ReplayLatencyMode`), and `--settings <path>` chooses the settings a replay
/// starts from (`LaunchFiles`).
///
/// Where a replay keeps its files is never an argument: it makes a directory of
/// its own and says which on the line it writes when it starts.
enum LaunchArguments {
  private static var openArgument: String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--open"), index + 1 < arguments.count else {
      return nil
    }
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
    // Before any window opens, so the first one is parked too.
    #if ControlAPI
      if AppState.shared.controlMode.parksWindows {
        WindowParking.start()
      }
    #endif
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
        AppActivation.request()
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
    // Before the line below, so the harness that reads it can connect at
    // once, and saying why on stderr when it cannot: the harness reads
    // that, not the menu.
    startControl()
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

  @MainActor private func startControl() {
    let state = AppState.shared
    if let refusal = state.controlMode.refusal {
      FileHandle.standardError.write(Data("control API refused: \(refusal)\n".utf8))
      return
    }
    #if ControlAPI
      guard case .on(let channel) = state.controlMode else { return }
      do {
        try ControlServer.start(channel, host: state)
        AppState.log.notice("control API listening at \(channel.socketPath, privacy: .public)")
      } catch {
        state.controlFailure = String(describing: error)
        AppState.log.error("control API failed: \(String(describing: error), privacy: .public)")
        FileHandle.standardError.write(Data("control API failed: \(error)\n".utf8))
      }
    #endif
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task { @MainActor in
      await AppState.shared.stop()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

/// The menu bar extra's menu, drawn from the app's `MenuModel`, whose
/// commands it runs through the handler the control API uses too.
struct MenuBarContent: View {
  @Environment(AppState.self)
  private var state

  var body: some View {
    MenuItems(items: state.menuModel.items)
  }
}

/// Rows of the menu or of one of its submenus.
private struct MenuItems: View {
  let items: [MenuModel.Item]

  @Environment(AppState.self)
  private var state

  var body: some View {
    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
      switch item {
      case .status(let line):
        Text(line)
      case .command(let title, let command, let enabled, let shortcut):
        Button(title) { state.perform(command) }
          .disabled(!enabled)
          .optionalKeyboardShortcut(shortcut.flatMap(Self.keyboardShortcut))
      case .separator:
        Divider()
      case .submenu(let title, let children, let enabled):
        Menu(title) { MenuItems(items: children) }
          .disabled(!enabled)
      }
    }
  }

  private static func keyboardShortcut(_ shortcut: MenuModel.Shortcut) -> KeyboardShortcut? {
    switch shortcut {
    case .hotKey(let hotKey): Formatting.keyboardShortcut(for: hotKey)
    case .command(let character): KeyboardShortcut(KeyEquivalent(character))
    }
  }
}
