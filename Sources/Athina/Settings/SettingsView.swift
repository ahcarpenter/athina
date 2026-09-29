import AppKit
import AthinaCore
import CoreGraphics
import Foundation
import Observation
import SwiftUI

/// A pane of the Settings window.
///
/// The last pane viewed is remembered, and `--open settings:<pane>` or a link
/// inside another pane can choose it.
enum SettingsPane: String, CaseIterable, Identifiable {
  case general, contexts, models, capture, journal, privacy, advanced

  static let storageKey = "SettingsPane"

  /// The scheme of a link from one pane's text to another pane
  /// (`link`, `settingsPaneLinks`), so the two can never name it differently.
  static let linkScheme = "athina-settings"

  var id: String { rawValue }

  /// The link text in another pane opens this pane by, as Markdown.
  func link(_ title: String) -> String {
    "[\(title)](\(SettingsPane.linkScheme):\(rawValue))"
  }

  var title: String {
    switch self {
    case .general: "General"
    case .contexts: "Contexts"
    case .models: "Models"
    case .capture: "Capture"
    case .journal: "Journal"
    case .privacy: "Privacy"
    case .advanced: "Advanced"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .contexts: "target"
    case .models: "cpu"
    case .capture: "camera.viewfinder"
    case .journal: "book.closed"
    case .privacy: "hand.raised"
    case .advanced: "gearshape.2"
    }
  }

  /// Opens the pane a `linkScheme` link names, as a click on the link does;
  /// false, doing nothing, for any other link.
  @MainActor
  static func open(link url: URL) -> Bool {
    guard url.scheme == linkScheme,
      let pane = SettingsPane(
        rawValue: url.absoluteString.replacingOccurrences(of: "\(linkScheme):", with: "")
      )
    else {
      return false
    }
    pane.select()
    return true
  }

  /// Makes this the pane the Settings window shows, now or when it next opens.
  @MainActor
  func select() {
    SettingsPaneSelection.shared.pane = self
  }
}

/// The pane the Settings window shows, remembered across launches in the
/// preferences.
///
/// A hermetic run keeps it to itself instead: every such run shares one
/// preferences domain (docs/e2e.md "Hermetic runs"), which would carry one run's
/// choice of pane into every other run's open Settings window.
@MainActor
@Observable
final class SettingsPaneSelection {
  static let shared = SettingsPaneSelection(remembers: !AppState.shared.controlMode.isHermetic)

  private let remembers: Bool

  var pane: SettingsPane {
    didSet {
      if remembers { UserDefaults.standard.set(pane.rawValue, forKey: SettingsPane.storageKey) }
    }
  }

  init(remembers: Bool) {
    self.remembers = remembers
    let saved = remembers ? UserDefaults.standard.string(forKey: SettingsPane.storageKey) : nil
    pane = saved.flatMap(SettingsPane.init(rawValue:)) ?? .general
  }
}

/// The Settings window: a standard toolbar of panes.
///
/// The window takes its title from the pane, and each pane is a grouped form of
/// a fixed size that scrolls when its settings run longer.
struct SettingsView: View {
  static let paneWidth: CGFloat = 600

  @Bindable private var selection = SettingsPaneSelection.shared

  var body: some View {
    TabView(selection: $selection.pane) {
      Tab(SettingsPane.general.title, systemImage: SettingsPane.general.symbol, value: .general) {
        GeneralSettings().settingsPane(height: 640)
      }
      Tab(SettingsPane.contexts.title, systemImage: SettingsPane.contexts.symbol, value: .contexts)
      {
        ContextsSettings().settingsPane(height: 520)
      }
      Tab(SettingsPane.models.title, systemImage: SettingsPane.models.symbol, value: .models) {
        ModelSettings().settingsPane(height: 640)
      }
      Tab(SettingsPane.capture.title, systemImage: SettingsPane.capture.symbol, value: .capture) {
        CaptureSettings().settingsPane(height: 640)
      }
      Tab(SettingsPane.journal.title, systemImage: SettingsPane.journal.symbol, value: .journal) {
        JournalSettings().settingsPane(height: 500)
      }
      Tab(SettingsPane.privacy.title, systemImage: SettingsPane.privacy.symbol, value: .privacy) {
        PrivacySettings().settingsPane(height: 560)
      }
      Tab(SettingsPane.advanced.title, systemImage: SettingsPane.advanced.symbol, value: .advanced)
      {
        AdvancedSettings().settingsPane(height: 180)
      }
    }
  }
}

extension Text {
  /// Text with a link to another Settings pane in it (`SettingsPane.link`),
  /// from Markdown.
  ///
  /// A string literal is the only Markdown `Text` parses on its own, and the
  /// link is built rather than written, so it is parsed here; text that would
  /// not parse is shown as it is.
  init(settingsMarkdown markdown: String) {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    if let parsed = try? AttributedString(markdown: markdown, options: options) {
      self.init(parsed)
    } else {
      self.init(verbatim: markdown)
    }
  }
}

extension View {
  /// A Settings pane: a grouped form at the pane's size.
  func settingsPane(height: CGFloat) -> some View {
    formStyle(.grouped)
      .frame(width: SettingsView.paneWidth, height: height)
  }

  /// Opens a `SettingsPane.linkScheme` link in this text (`SettingsPane.link`)
  /// as that Settings pane, so text names a place elsewhere in Settings by
  /// linking to it.
  func settingsPaneLinks() -> some View {
    environment(
      \.openURL,
      OpenURLAction { url in
        SettingsPane.open(link: url) ? .handled : .systemAction
      }
    )
  }
}

// MARK: - Capture

struct CaptureSettings: View {
  @Environment(AppState.self)
  private var state

  var body: some View {
    @Bindable var state = state
    Form {
      Section(
        content: {
          NumberRow(
            "Wait after switching windows",
            value: $state.settings.focusSettleDelay,
            range: 0...5,
            step: 0.05,
            unit: .seconds,
            help: "Gives the new window time to finish drawing before it is captured."
          )
          NumberRow(
            "Wait after typing or clicking",
            value: $state.settings.inputSettleDelay,
            range: 0.1...30,
            step: 0.1,
            unit: .seconds,
            help: "Quiet time after keyboard, mouse, or trackpad input before a capture."
          )
          NumberRow(
            "Capture at least every",
            value: $state.settings.floorInterval,
            range: 1...600,
            step: 1,
            unit: .seconds,
            help: "A slow, steady capture while you are active, even when nothing triggers one."
          )
          NumberRow(
            "Capture at most every",
            value: $state.settings.minCaptureInterval,
            range: 0.1...60,
            step: 0.05,
            unit: .seconds,
            help: "The shortest time between two captures, whatever triggered them."
          )
        },
        header: {
          Text("When to capture")
        }
      )
      Section(
        content: {
          NumberRow(
            "Idle after",
            value: $state.settings.idleThreshold,
            range: 5...3600,
            step: 5,
            unit: .seconds,
            help: "Sensing stops after this long without keyboard, mouse, or trackpad input."
          )
          NumberRow(
            "Check for input while active every",
            value: $state.settings.inputPollInterval,
            range: 0.1...5,
            step: 0.1,
            unit: .seconds
          )
          NumberRow(
            "Check for input while idle every",
            value: $state.settings.idlePollInterval,
            range: 0.5...30,
            step: 0.5,
            unit: .seconds
          )
          HStack {
            Spacer()
            Button("Restore Default Timing") {
              let defaults = SensingSettings()
              var restored = state.settings
              restored.focusSettleDelay = defaults.focusSettleDelay
              restored.inputSettleDelay = defaults.inputSettleDelay
              restored.floorInterval = defaults.floorInterval
              restored.minCaptureInterval = defaults.minCaptureInterval
              restored.idleThreshold = defaults.idleThreshold
              restored.inputPollInterval = defaults.inputPollInterval
              restored.idlePollInterval = defaults.idlePollInterval
              state.settings = restored
            }
          }
        },
        header: {
          Text("Idle")
        }
      )
      Section(
        content: {
          IntRow(
            "Longest frame edge",
            value: $state.settings.maxFrameDimension,
            range: 320...4096,
            step: 64,
            unit: .pixels,
            help:
              """
              Frames are scaled down to this size. Smaller frames are cheaper to compare, \
              read, and store.
              """
          )
          IntRow(
            "Treat frames as unchanged within",
            value: $state.settings.hashDistanceThreshold,
            range: 0...PerceptualHash.bitCount,
            step: 1,
            unit: .bits,
            help:
              """
              A frame this close to the previous one, out of \(PerceptualHash.bitCount) bits \
              of its fingerprint, is dropped unless the window or the focused text changed.
              """
          )
        },
        header: {
          Text("Frames")
        }
      )
      Section(
        content: {
          Picker(
            selection: $state.settings.ocrLevel,
            content: {
              ForEach(OCRLevel.allCases) { level in
                Text(level.label).tag(level)
              }
            },
            label: {
              Text("Text recognition")
              Text(
                """
                Accurate takes a few hundred milliseconds per frame. Fast is much quicker but \
                finds no text in dark interfaces such as terminals.
                """
              )
            }
          )
          .pickerStyle(.segmented)
          PercentRow(
            "Thumbnail quality",
            value: $state.settings.thumbnailJPEGQuality,
            range: 0.1...1,
            step: 0.05
          )
        },
        header: {
          Text("Recognition and storage")
        }
      )
    }
  }
}

// MARK: - Journal

struct JournalSettings: View {
  @Environment(AppState.self)
  private var state

  @State private var confirmClear = false

  var body: some View {
    @Bindable var state = state
    Form {
      Section(
        content: {
          DurationRow("Keep thumbnails for", value: $state.settings.thumbnailRetention)
          DurationRow(
            "Keep text and events for",
            value: $state.settings.textRetention,
            help: "Always at least as long as thumbnails."
          )
          NumberRow(
            "Limit the journal to",
            value: Binding(
              get: { Double(state.settings.journalSizeCapBytes / (1024 * 1024)) },
              set: {
                state.settings.journalSizeCapBytes =
                  Int64($0.clamped(to: 10...100_000)) * 1024 * 1024
              }
            ),
            range: 10...100_000,
            step: 50,
            unit: .megabytes,
            help:
              """
              The oldest thumbnails, then the oldest text and events, are removed to stay \
              under this size.
              """
          )
          NumberRow(
            "Clean up every",
            value: $state.settings.retentionInterval,
            range: 30...86400,
            step: 30,
            unit: .seconds
          )
        },
        header: {
          Text("Retention")
        }
      )
      Section(
        content: {
          LabeledContent("Location") {
            Text(Formatting.path(state.journalURL))
              .textSelection(.enabled)
              .multilineTextAlignment(.trailing)
              .fixedSize(horizontal: false, vertical: true)
          }
          if let stats = state.journalStats {
            LabeledContent("Size", value: Formatting.bytes(stats.usedBytes))
            LabeledContent("Contents") {
              Text(
                """
                \(Plural.count(stats.observationCount, "observation", "observations")), \
                \(Plural.count(stats.thumbnailCount, "thumbnail", "thumbnails")), \
                \(Plural.count(stats.eventCount, "event", "events"))
                """
              )
              .multilineTextAlignment(.trailing)
              .fixedSize(horizontal: false, vertical: true)
            }
          }
          HStack {
            Button("Reveal in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([state.journalURL])
            }
            Spacer()
            Button("Clear Journal…", role: .destructive) {
              confirmClear = true
            }
            .accessibilityIdentifier("journal.clear")
          }
        },
        header: {
          Text("On disk")
        }
      )
    }
    // Clearing is what the person just chose, so the confirming button
    // is the plain default and Cancel stays available.
    .confirmationDialog(
      "Clear the journal?",
      isPresented: $confirmClear,
      titleVisibility: .visible,
      actions: {
        Button("Clear Journal") {
          Task { await state.clearJournal() }
        }
        Button("Cancel", role: .cancel) {}
      },
      message: {
        Text(
          """
          Every observation, thumbnail, event, suggestion, follow-up question, and model call \
          record is deleted, along with Athina's understanding of what you are working toward. \
          You can't undo this action.
          """
        )
      }
    )
    .task {
      await state.refreshJournalStats()
    }
  }
}

// MARK: - Privacy

struct PrivacySettings: View {
  @Environment(AppState.self)
  private var state

  @Environment(\.undoManager)
  private var undoManager

  @State private var showAdd = false
  @State private var removals = RemovalUndo<String>()

  var body: some View {
    @Bindable var state = state
    Form {
      Section(
        content: {
          LabeledContent(
            content: {
              StatusBadge(
                text: state.settings.hasConsent ? "Allowed" : "Not allowed",
                status: state.settings.hasConsent ? .good : .attention
              )
            },
            label: {
              Text("Watch the screen and send to \(state.settings.mentor.provider.name)")
              Text(consentDetail)
            }
          )
          HStack {
            Link("Privacy Policy", destination: Consent.privacyPolicyURL)
            Spacer()
            if state.settings.hasConsent {
              Button("Withdraw Consent") { state.withdrawConsent() }
                .accessibilityIdentifier("privacy.withdrawConsent")
            } else {
              Button("Review and Allow…") { state.perform(.openConsent) }
                .accessibilityIdentifier("privacy.reviewConsent")
            }
          }
        },
        header: {
          Text("Consent")
        },
        footer: {
          Text(
            settingsMarkdown:
              "Withdrawing stops all capturing and sending at once. What the journal already holds stays until it expires or you clear it in \(SettingsPane.journal.link("Journal"))."
          )
          .settingsPaneLinks()
        }
      )
      Section(
        content: {
          LabeledContent(
            content: {
              ShortcutRecorder(
                title: "Pause shortcut",
                identifier: "privacy.pauseShortcut",
                hotKey: $state.settings.pauseShortcut,
                conflicts: [state.settings.mentor.pushToTalkHotKey].compactMap { $0 },
                conflictNote: "This keyboard shortcut is already the talk-back shortcut."
              )
            },
            label: {
              Text("Pause shortcut")
              if state.isRunning, let key = state.settings.pauseShortcut, !state.hotKeyRegistered {
                StatusLabel(ShortcutProblem.sentence(for: key), kind: .warning)
              }
            }
          )
        },
        footer: {
          Text(
            """
            Pauses and resumes watching from any app. While paused, the eyes in the menu bar \
            are shut.
            """
          )
        }
      )
      Section(
        content: {
          HStack {
            Button("Add App…") { showAdd = true }
              .popover(isPresented: $showAdd, arrowEdge: .bottom) {
                AddExcludedAppPopover(existing: state.settings.excludedBundleIDs) { id in
                  state.settings.excludedBundleIDs.append(id)
                }
              }
            Spacer()
            Button("Restore Defaults") {
              state.settings.excludedBundleIDs = ExcludedApps.defaults
            }
            .disabled(state.settings.excludedBundleIDs == ExcludedApps.defaults)
          }
          let excluded = state.settings.excludedBundleIDs
          let installed = excluded.filter(ExcludedAppRow.isInstalled)
          ForEach(installed, id: \.self) { id in
            excludedRow(id)
          }
          // Apps this Mac does not have are listed only on request: most of
          // the defaults are password managers a given Mac never installed.
          let missing = excluded.filter { !ExcludedAppRow.isInstalled($0) }
          if !missing.isEmpty {
            DisclosureGroup(
              content: {
                ForEach(missing, id: \.self) { id in
                  excludedRow(id)
                }
              },
              label: {
                Text(
                  Plural.count(
                    missing.count,
                    "app that is not installed",
                    "apps that are not installed"
                  )
                )
              }
            )
            .accessibilityIdentifier("privacy.notInstalledApps")
          }
          UndoRemovalRow(
            undo: removals,
            list: $state.settings.excludedBundleIDs,
            identifier: "privacy.undoRemoveApp"
          )
        },
        header: {
          Text("Excluded apps")
        },
        footer: {
          Text(
            """
            While one of these apps is frontmost, Athina captures nothing, reads no window or \
            element, and journals only that the app was excluded. Password fields in any app \
            are never read either.
            """
          )
        }
      )
    }
  }

  private func excludedRow(_ id: String) -> some View {
    @Bindable var state = state
    return ExcludedAppRow(bundleID: id) { name in
      guard let index = state.settings.excludedBundleIDs.firstIndex(of: id) else { return }
      removals.remove(
        at: index,
        named: name,
        from: $state.settings.excludedBundleIDs,
        clock: state.clock,
        undoManager: undoManager
      )
    }
  }
}

extension PrivacySettings {
  /// What the answer is and when it was given, or what not having one means.
  private var consentDetail: String {
    guard let consent = state.settings.consent(for: state.settings.mentor.provider) else {
      return "Not asked yet. Athina captures nothing and sends nothing until you allow it."
    }
    let when = consent.at.formatted(date: .abbreviated, time: .shortened)
    if state.settings.hasConsent { return "Allowed \(when)." }
    switch consent.answer {
    case .allowed:
      return "Allowed \(when) to an earlier description of what is sent, so Athina asks again."
    case .declined: return "Not allowed since \(when). Athina captures nothing and sends nothing."
    }
  }
}

/// An excluded app: its icon and name when it is installed, its bundle
/// identifier always, and a button that removes it.
private struct ExcludedAppRow: View {
  let bundleID: String
  /// Removes the app, given the name the row shows for it.
  let onRemove: (String) -> Void

  private var appURL: URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
  }

  static func isInstalled(_ bundleID: String) -> Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
  }

  var body: some View {
    let url = appURL
    let name = url.map(appName) ?? bundleID
    LabeledContent(
      content: {
        RemoveButton(itemName: name) { onRemove(name) }
      },
      label: {
        Label(
          title: {
            Text(url.map(appName) ?? bundleID)
            Text(url == nil ? "Not installed" : bundleID)
          },
          icon: {
            if let url {
              Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            } else {
              Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            }
          }
        )
      }
    )
  }

  private func appName(_ url: URL) -> String {
    FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
  }
}

/// An icon-only button that removes one item from a list, labeled for
/// VoiceOver and the pointer with what it removes.
///
/// The glyph keeps its size, and the area that takes the click is the HIG's
/// 20 by 20 point minimum for macOS around it.
struct RemoveButton: View {
  static let minimumHitSize: CGFloat = 20

  let itemName: String
  let action: () -> Void

  var body: some View {
    Button(role: .destructive, action: action) {
      Label("Remove \(itemName)", systemImage: "minus.circle")
        .labelStyle(.iconOnly)
        .frame(minWidth: Self.minimumHitSize, minHeight: Self.minimumHitSize)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help("Remove \(itemName)")
  }
}

/// The last item removed from a list, and where it was, so Undo can put it
/// back.
struct Removal<Item: Equatable>: Equatable {
  /// The item as it was.
  let item: Item
  /// Its place in the list.
  let index: Int
  /// What it is called, for the row that offers Undo and for VoiceOver.
  let name: String

  /// The list with the item back at its place, unless it is there already.
  func restored(in list: [Item]) -> [Item] {
    guard !list.contains(item) else { return list }
    var list = list
    list.insert(item, at: min(index, list.count))
    return list
  }
}

/// Removes items from a list on one click, and keeps the last removal so it
/// can be undone, as the HIG asks of a common, cheap destructive action
/// instead of an alert: from the row this puts under the list for a while,
/// or with Edit > Undo while the Settings window is in front.
@MainActor
@Observable
final class RemovalUndo<Item: Equatable> {
  /// How long the Undo row stays under the list after a removal.
  static var shownFor: Duration { .seconds(10) }

  private(set) var last: Removal<Item>?
  /// The undo manager's action for `last`, taken off its stack when the row
  /// undoes the removal instead.
  private var lastRegistration: Registration?
  private var expiry: Task<Void, Never>?

  /// One removal's place on an undo manager's stack.
  private final class Registration {
    weak var undoManager: UndoManager?

    init(undoManager: UndoManager?) {
      self.undoManager = undoManager
    }
  }

  /// Removes the item at `index` of the list `list` reads and writes, and
  /// keeps it for Undo.
  func remove(
    at index: Int,
    named name: String,
    from list: Binding<[Item]>,
    clock: any AthinaClock,
    undoManager: UndoManager?
  ) {
    guard list.wrappedValue.indices.contains(index) else { return }
    let removal = Removal(item: list.wrappedValue[index], index: index, name: name)
    list.wrappedValue.remove(at: index)
    let registration = Registration(undoManager: undoManager)
    last = removal
    lastRegistration = registration
    Announce.post("Removed \(name)")
    undoManager?.registerUndo(withTarget: registration) { _ in
      MainActor.assumeIsolated { self.restore(removal, registeredAs: registration, into: list) }
    }
    undoManager?.setActionName("Remove \(name)")
    expiry?.cancel()
    expiry = Task { [weak self] in
      try? await clock.sleep(for: Self.shownFor)
      guard !Task.isCancelled, let self, self.lastRegistration === registration else { return }
      self.last = nil
      self.lastRegistration = nil
    }
  }

  /// Puts the last removal back, from the row under the list.
  func undo(into list: Binding<[Item]>) {
    guard let removal = last, let registration = lastRegistration else { return }
    registration.undoManager?.removeAllActions(withTarget: registration)
    restore(removal, registeredAs: registration, into: list)
  }

  /// Puts `removal` back, and stops offering it in the row if it is the last.
  private func restore(
    _ removal: Removal<Item>,
    registeredAs registration: Registration,
    into list: Binding<[Item]>
  ) {
    list.wrappedValue = removal.restored(in: list.wrappedValue)
    if lastRegistration === registration {
      last = nil
      lastRegistration = nil
      expiry?.cancel()
    }
    Announce.post("Restored \(removal.name)")
  }
}

/// "Removed 1Password." with Undo, under a list for a while after a removal.
struct UndoRemovalRow<Item: Equatable>: View {
  let undo: RemovalUndo<Item>
  let list: Binding<[Item]>
  /// The Undo button's accessibility identifier, for the end-to-end harness.
  let identifier: String

  var body: some View {
    if let removal = undo.last {
      LabeledContent(
        content: {
          Button("Undo") { undo.undo(into: list) }
            .accessibilityLabel("Undo removing \(removal.name)")
            .accessibilityIdentifier(identifier)
        },
        label: {
          Text("Removed \(removal.name).")
        }
      )
    }
  }
}

private struct AddExcludedAppPopover: View {
  let existing: [String]
  let onAdd: (String) -> Void

  @Environment(\.dismiss)
  private var dismiss

  @State private var bundleID = ""

  private var runningApps: [(name: String, id: String)] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular }
      .compactMap { app in
        guard let id = app.bundleIdentifier,
          !existing.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame })
        else { return nil }
        return (app.localizedName ?? id, id)
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Exclude an App")
        .font(.headline)
      Menu("Choose a Running App") {
        ForEach(runningApps, id: \.id) { app in
          Button(app.name) { bundleID = app.id }
        }
      }
      .fixedSize()
      TextField("Bundle identifier", text: $bundleID, prompt: Text("com.example.App"))
        .textFieldStyle(.roundedBorder)
        .onSubmit(add)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Add", action: add)
          .keyboardShortcut(.defaultAction)
          .disabled(bundleID.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding()
    .frame(width: 340)
  }

  private func add() {
    let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { return }
    onAdd(id)
    dismiss()
  }
}

/// Why a keyboard shortcut Settings holds is not working: the one reason
/// that applies, not a list of possible ones.
enum ShortcutProblem {
  static func sentence(for key: HotKey) -> String {
    key.isUsable
      ? "Another app uses this combination. Choose another."
      : """
      This combination has no Control, Option, or Command key, so it would take a key you \
      type. Choose another.
      """
  }
}

// MARK: - Rows

/// The unit a number row counts in, written out for the row and for VoiceOver.
enum SettingsUnit {
  case seconds, pixels, bits, tokens, megabytes

  func label(for value: Double) -> String {
    let one = value == 1
    switch self {
    case .seconds: return one ? "second" : "seconds"
    case .pixels: return one ? "pixel" : "pixels"
    case .bits: return one ? "bit" : "bits"
    case .tokens: return one ? "token" : "tokens"
    case .megabytes: return "MB"
    }
  }
}

/// A number with a field for typing it, a stepper for nudging it, and its unit.
///
/// The label can carry a line of help underneath, styled by the form; a row
/// counting seconds says its range there too.
struct NumberRow: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  let unit: SettingsUnit
  var help: String?

  init(
    _ title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    unit: SettingsUnit,
    help: String? = nil
  ) {
    self.title = title
    _value = value
    self.range = range
    self.step = step
    self.unit = unit
    self.help = help
  }

  private static let format = FloatingPointFormatStyle<Double>.number.precision(
    .fractionLength(0...2)
  )

  private var spokenTitle: String { "\(title), in \(unit.label(for: value))" }

  private func amount(_ number: Double) -> String {
    "\(number.formatted(Self.format)) \(unit.label(for: number))"
  }

  var body: some View {
    RangedRow(
      title: title,
      help: unit == .seconds ? Ranged.withRange(help, range, amount) : help,
      value: $value,
      range: range,
      describe: amount,
      controls: { draft, editing, onCommit in
        NumberControls(
          unitLabel: unit.label(for: value),
          field: TextField(spokenTitle, value: draft, format: Self.format),
          stepper: Stepper(title, value: $value, in: range, step: step),
          editing: editing,
          onCommit: onCommit
        )
      }
    )
  }
}

struct IntRow: View {
  let title: String
  @Binding var value: Int
  let range: ClosedRange<Int>
  let step: Int
  let unit: SettingsUnit
  var help: String?

  init(
    _ title: String,
    value: Binding<Int>,
    range: ClosedRange<Int>,
    step: Int,
    unit: SettingsUnit,
    help: String? = nil
  ) {
    self.title = title
    _value = value
    self.range = range
    self.step = step
    self.unit = unit
    self.help = help
  }

  private var spokenTitle: String { "\(title), in \(unit.label(for: Double(value)))" }

  var body: some View {
    RangedRow(
      title: title,
      help: help,
      value: $value,
      range: range,
      describe: { "\($0.formatted(.number)) \(unit.label(for: Double($0)))" },
      controls: { draft, editing, onCommit in
        NumberControls(
          unitLabel: unit.label(for: Double(value)),
          field: TextField(spokenTitle, value: draft, format: .number.grouping(.never)),
          stepper: Stepper(title, value: $value, in: range, step: step),
          editing: editing,
          onCommit: onCommit
        )
      }
    )
  }
}

/// An amount of money, typed and shown in dollars, its range said in its help.
struct DollarRow: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  var help: String?
  /// The field's accessibility identifier, for the end-to-end harness
  /// (docs/e2e.md "The control API").
  var identifier: String?

  init(
    _ title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    help: String? = nil,
    identifier: String? = nil
  ) {
    self.title = title
    _value = value
    self.range = range
    self.step = step
    self.help = help
    self.identifier = identifier
  }

  private static let format = FloatingPointFormatStyle<Double>.Currency(code: "USD")

  var body: some View {
    RangedRow(
      title: title,
      help: Ranged.withRange(help, range) { $0.formatted(Self.format) },
      value: $value,
      range: range,
      describe: { $0.formatted(Self.format) },
      controls: { draft, editing, onCommit in
        NumberControls(
          unitLabel: nil,
          field: TextField(title, value: draft, format: Self.format)
            .accessibilityIdentifier(identifier ?? ""),
          stepper: Stepper(title, value: $value, in: range, step: step),
          editing: editing,
          onCommit: onCommit
        )
      }
    )
  }
}

/// A fraction from 0 to 1, typed and shown as a percentage.
struct PercentRow: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  var help: String?

  init(
    _ title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    help: String? = nil
  ) {
    self.title = title
    _value = value
    self.range = range
    self.step = step
    self.help = help
  }

  private static let format = FloatingPointFormatStyle<Double>.Percent.percent.precision(
    .fractionLength(0)
  )

  var body: some View {
    RangedRow(
      title: title,
      help: help,
      value: $value,
      range: range,
      describe: { $0.formatted(Self.format) },
      controls: { draft, editing, onCommit in
        NumberControls(
          unitLabel: nil,
          field: TextField(title, value: draft, format: Self.format),
          stepper: Stepper(title, value: $value, in: range, step: step),
          editing: editing,
          onCommit: onCommit
        )
      }
    )
  }
}

/// Help text for a row, with the range the row accepts after it.
enum Ranged {
  static func withRange<Value>(
    _ help: String?,
    _ range: ClosedRange<Value>,
    _ describe: (Value) -> String
  ) -> String {
    let span = "From \(describe(range.lowerBound)) to \(describe(range.upperBound))."
    return help.map { "\($0) \(span)" } ?? span
  }
}

/// A number row's label and controls around a field that edits a local
/// draft, not the setting itself.
///
/// The draft is written to the setting as the edit ends, however it ends,
/// held inside `range`, so `MentorSettings.validated()`, which runs on every
/// change of the settings, never gets a number to correct out of sight. When
/// the typed number was outside the range the row says what it was set to and
/// what the range is, and VoiceOver hears it, until the setting next changes.
private struct RangedRow<Value: Comparable & Sendable, Controls: View>: View {
  let title: String
  let help: String?
  @Binding var value: Value
  let range: ClosedRange<Value>
  let describe: (Value) -> String
  @ViewBuilder
  let controls: (Binding<Value>, FocusState<Bool>.Binding, @escaping () -> Void) -> Controls

  @State private var draft: Value?
  @FocusState private var editing: Bool
  /// The number the setting was set to after a typed one outside the range.
  @State private var corrected: Value?

  var body: some View {
    let field = Binding(get: { draft ?? value }, set: { draft = $0 })
    LabeledContent(
      content: {
        controls(field, $editing, push)
      },
      label: {
        Text(title)
        if let help { Text(help) }
        if let corrected {
          StatusLabel(correction(corrected), kind: .info)
        }
      }
    )
    // However the field commits its text, before or after focus leaves it,
    // what it typed is pushed once the edit is over.
    .onChange(of: editing) { _, focused in
      if !focused { push() }
    }
    .onChange(of: draft) { _, typed in
      if typed != nil, !editing { push() }
    }
    .onChange(of: value) { _, newValue in
      // The stepper, or a change from elsewhere: the draft follows it, and a
      // correction the setting has moved on from is no longer news.
      draft = nil
      if newValue != corrected { corrected = nil }
    }
  }

  private func correction(_ settled: Value) -> String {
    """
    Set to \(describe(settled)), since it can be from \(describe(range.lowerBound)) to \
    \(describe(range.upperBound)).
    """
  }

  private func push() {
    guard let typed = draft else { return }
    let settled = typed.clamped(to: range)
    draft = nil
    if settled != typed {
      corrected = settled
      Announce.post(correction(settled))
    }
    if settled != value { value = settled }
  }
}

/// The trailing controls of a number row.
///
/// The field and stepper are titled with the row's title, the field's with its
/// unit too, which VoiceOver reads once; a separate accessibility label would
/// be read beside that title. The field commits as its edit ends, on Return or
/// when focus leaves it.
private struct NumberControls<Field: View, StepperView: View>: View {
  let unitLabel: String?
  let field: Field
  let stepper: StepperView
  let editing: FocusState<Bool>.Binding
  let onCommit: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      field
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(width: 72)
        .focused(editing)
        .onSubmit(onCommit)
      stepper
        .labelsHidden()
      if let unitLabel {
        Text(unitLabel)
          .foregroundStyle(.secondary)
          .frame(minWidth: 52, alignment: .leading)
          .accessibilityHidden(true)
      }
    }
  }
}

/// A duration with a field, a stepper, and a unit menu, for retention periods.
struct DurationRow: View {
  let title: String
  @Binding var value: TimeInterval
  /// The seconds the setting itself accepts, where it bounds them.
  ///
  /// A unit is offered only where the range holds a whole amount of it, and the
  /// stepper and a typed amount are held inside it, so the row cannot offer a
  /// duration `MentorSettings.validated()` would clamp away.
  let range: ClosedRange<TimeInterval>?
  var help: String?
  /// The amount field's accessibility identifier, for the end-to-end
  /// harness (docs/e2e.md "The control API").
  var identifier: String?

  private enum Unit: String, CaseIterable, Identifiable {
    case minutes, hours, days
    var id: String { rawValue }
    var seconds: Double {
      switch self {
      case .minutes: 60
      case .hours: 3600
      case .days: 86400
      }
    }
  }

  /// The width the unit pop-up reserves.
  ///
  /// A menu-style Picker sizes to the unit it is showing, not to the widest in
  /// its menu, and a form's rows are trailing aligned, so a row showing
  /// "minutes" puts its field and stepper 12 pt left of a row showing "hours".
  /// Reserving what a pop-up needs for the widest unit word holds every
  /// duration row on one x whatever unit each is showing, and measuring it
  /// rather than naming a number keeps that true whatever font the control
  /// draws in.
  @MainActor private static let unitWidth: CGFloat = {
    let sizing = NSPopUpButton(frame: .zero, pullsDown: false)
    sizing.addItems(withTitles: Unit.allCases.map(\.rawValue))
    return sizing.intrinsicContentSize.width
  }()

  @State private var amount: Double = 1
  @State private var unit: Unit = .hours
  @FocusState private var editing: Bool

  init(
    _ title: String,
    value: Binding<TimeInterval>,
    range: ClosedRange<TimeInterval>? = nil,
    help: String? = nil,
    identifier: String? = nil
  ) {
    self.title = title
    _value = value
    self.range = range
    self.help = help
    self.identifier = identifier
  }

  /// The whole amounts of `unit` the range allows, or the unbounded row's own
  /// 1...10_000 where the setting has no range.
  ///
  /// Nil where the range holds no whole amount of the unit, which is how that
  /// unit is left out.
  private func amounts(in unit: Unit) -> ClosedRange<Double>? {
    guard let range else { return 1...10_000 }
    let low = max(1, (range.lowerBound / unit.seconds).rounded(.up))
    let high = (range.upperBound / unit.seconds).rounded(.down)
    return low <= high ? low...high : nil
  }

  private var units: [Unit] { Unit.allCases.filter { amounts(in: $0) != nil } }

  var body: some View {
    LabeledContent(
      content: {
        HStack(spacing: 6) {
          TextField(
            "\(title), in \(unit.rawValue)",
            value: $amount,
            format: .number.precision(.fractionLength(0...1))
          )
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .frame(width: 72)
          .accessibilityIdentifier(identifier ?? "")
          .focused($editing)
          .onSubmit(push)
          // A field writes the setting when its editing ends, however
          // it ends, not only when Return commits it.
          .onChange(of: editing) { _, focused in
            if !focused { push() }
          }
          Stepper(title, value: $amount, in: amounts(in: unit) ?? 1...10_000, step: 1) { _ in push()
          }
          .labelsHidden()
          Picker("\(title) unit", selection: $unit) {
            ForEach(units) { unit in
              Text(unit.rawValue).tag(unit)
            }
          }
          .labelsHidden()
          // A minimum rather than a width, so a unit word wider than the
          // measurement grows the control instead of clipping, and
          // trailing so the pop-up keeps the form's edge and the slack a
          // shorter word leaves falls between it and the stepper.
          .frame(minWidth: Self.unitWidth, alignment: .trailing)
          .onChange(of: unit) { _, _ in push() }
        }
      },
      label: {
        Text(title)
        if let help { Text(help) }
      }
    )
    .onAppear(perform: pull)
    .onChange(of: value) { _, newValue in
      if newValue != amount * unit.seconds { pull() }
    }
  }

  private func pull() {
    let seconds = value
    let offered = units
    let chosen: Unit
    if offered.contains(.days),
      seconds >= 86400,
      seconds.truncatingRemainder(dividingBy: 86400) == 0
    {
      chosen = .days
    } else if offered.contains(.hours), seconds >= 3600 {
      chosen = .hours
    } else {
      chosen = offered.first ?? .minutes
    }
    unit = chosen
    amount = (seconds / chosen.seconds * 10).rounded() / 10
  }

  private func push() {
    let seconds = amount * unit.seconds
    let bounded = range.map { seconds.clamped(to: $0) } ?? max(60, seconds)
    value = bounded
    amount = (bounded / unit.seconds * 10).rounded() / 10
  }
}

extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
