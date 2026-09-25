import AppKit
import AthinaCore
import SwiftUI

/// Owns the floating suggestion panel: a non-activating window that never takes
/// keyboard focus, placed under the menu bar at the top right of the screen the
/// user is working on.
///
/// With no suggestion up it can show a short note instead, for a talk-back key
/// press that has nothing to reply to.
///
/// Because the panel never becomes key, VoiceOver hears about it through
/// announcements, and the menu bar menu offers its answers to the keyboard.
@MainActor
final class ToastController {
  static let width: CGFloat = 380
  /// The panel is the toast plus a point on each side, so the glass edge is
  /// never clipped by the window.
  static let panelWidth: CGFloat = width + 2
  static let margin: CGFloat = 12
  static let noteDuration: TimeInterval = 4

  var onAction: ((Int64, SuggestionFeedback) -> Void)?
  var onHover: ((Bool) -> Void)?

  private var panel: NSPanel?
  private var hosting: NSHostingView<ToastView>?
  private var model = ToastModel()
  private var outsideClickMonitors: [Any] = []
  private var noteTask: Task<Void, Never>?
  /// What a note's time on screen is waited out on.
  private let clock: any AthinaClock
  /// Whether clicks outside Athina's own windows reach the toast.
  ///
  /// A hermetic run's never do, so whoever is using the Mac cannot dismiss a
  /// toast they cannot see; the control API's `outside-click` stands in.
  private let watchesOtherApps: Bool

  init(clock: any AthinaClock, watchesOtherApps: Bool = true) {
    self.clock = clock
    self.watchesOtherApps = watchesOtherApps
  }

  var isShowingSuggestion: Bool { model.suggestion != nil && (panel?.isVisible ?? false) }

  func show(_ suggestion: Suggestion, expanded: Bool, exchange: [FollowUp]) {
    noteTask?.cancel()
    model.note = nil
    model.suggestion = suggestion
    model.expanded = expanded
    model.exchange = exchange
    model.talkBack = .idle
    present()
    startWatchingForOutsideClicks()
    ToastController.announce(
      "Athina suggestion: \(suggestion.title). \(suggestion.body)",
      priority: .high
    )
  }

  func dismiss() {
    stopWatchingForOutsideClicks()
    noteTask?.cancel()
    model.suggestion = nil
    model.exchange = []
    model.talkBack = .idle
    model.note = nil
    panel?.orderOut(nil)
  }

  /// Orders the toast above anything shown since, such as a callout.
  func bringToFront() {
    guard let panel, panel.isVisible else { return }
    panel.orderFrontRegardless()
  }

  func expand() {
    model.expanded = true
    if let suggestion = model.suggestion {
      ToastController.announce(suggestion.explanation, priority: .high)
    }
  }

  /// While the user is talking back the toast stays where it is: it is
  /// brought to the front so no window covers it, and no click, timeout,
  /// or hover can take it down until the exchange is over.
  func setTalkBack(_ state: TalkBackState) {
    let previous = model.talkBack
    model.talkBack = state
    if state.keepsToastUp {
      bringToFront()
    }
    switch state {
    case .listening where !previous.isListening:
      ToastController.announce("Listening", priority: .medium)
    case .thinking where !previous.isThinking:
      ToastController.announce("Asking the mentor", priority: .medium)
    case .idle, .listening, .waiting, .thinking:
      break
    }
  }

  func setExchange(_ exchange: [FollowUp]) {
    if let latest = exchange.last,
      latest.id != model.exchange.last?.id || latest.answer != model.exchange.last?.answer
    {
      ToastController.announce(
        latest.answer.map { "Athina answered: \($0)" }
          ?? "No answer: \(latest.error ?? "unknown error")",
        priority: .high
      )
    }
    model.exchange = exchange
  }

  func setTalkBackKey(_ key: String?) {
    model.talkBackKey = key
  }

  /// A short line for the user: inside the toast when a suggestion is up,
  /// otherwise as a small panel of its own.
  ///
  /// It clears itself.
  func showNote(_ text: String) {
    noteTask?.cancel()
    model.note = text
    if model.suggestion == nil {
      present()
    }
    ToastController.announce(text, priority: .medium)
    let clock = clock
    noteTask = Task { [weak self] in
      try? await clock.sleep(for: .seconds(ToastController.noteDuration))
      guard !Task.isCancelled, let self, self.model.note == text else { return }
      self.model.note = nil
      if self.model.suggestion == nil {
        self.panel?.orderOut(nil)
      }
    }
  }

  private func present() {
    let panel = panel ?? makePanel()
    // A window that zooms in is motion; with Reduce Motion it just appears.
    panel.animationBehavior =
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .utilityWindow
    // The screen the pointer is on, but in a hermetic run, which reads
    // nothing of the person's input, always the main one.
    let mouse = watchesOtherApps ? NSEvent.mouseLocation : nil
    let screen =
      NSScreen.screens.first { mouse.map($0.frame.contains) ?? false } ?? NSScreen.main
      ?? NSScreen.screens.first
    place(panel, on: screen)
    panel.orderFrontRegardless()
  }

  /// Tells VoiceOver what appeared, since the panel never takes focus.
  private static func announce(_ text: String, priority: NSAccessibilityPriorityLevel) {
    NSAccessibility.post(
      element: NSApp as Any,
      notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: priority.rawValue]
    )
  }

  // MARK: Outside clicks

  /// A mouse-down anywhere but the toast or Athina's menu bar item dismisses it
  /// (`ToastClick`).
  ///
  /// The global monitor sees clicks in other apps, on the desktop, and on the
  /// menu bar, which carry no window of ours; the local one sees clicks in
  /// Athina's own windows and passes every event through, so an event aimed at
  /// the toast's own panel keeps it up and its buttons still work. A click
  /// inside the menu bar item's frame, whichever monitor sees it, opens the
  /// menu that answers the toast. Only mouse-down is watched, so scrolling,
  /// typing, and moving the pointer leave the toast alone. Neither monitor
  /// makes the panel key or activates the app.
  private func startWatchingForOutsideClicks() {
    guard outsideClickMonitors.isEmpty else { return }
    let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    if watchesOtherApps,
      let global = NSEvent.addGlobalMonitorForEvents(
        matching: clicks,
        handler: { [weak self] event in
          MainActor.assumeIsolated { self?.handleClick(event) }
        }
      )
    {
      outsideClickMonitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(
      matching: clicks,
      handler: { [weak self] event in
        MainActor.assumeIsolated { self?.handleClick(event) }
        return event
      }
    ) {
      outsideClickMonitors.append(local)
    }
  }

  private func stopWatchingForOutsideClicks() {
    for monitor in outsideClickMonitors { NSEvent.removeMonitor(monitor) }
    outsideClickMonitors.removeAll()
  }

  private func handleClick(_ event: NSEvent) {
    let location =
      event.window.map { $0.convertPoint(toScreen: event.locationInWindow) }
      ?? event.locationInWindow
    handleClick(at: location, onToast: event.window != nil && event.window === panel)
  }

  /// A mouse-down outside Athina's windows at `location`, in screen
  /// coordinates, as the global monitor reports one: how the control API's
  /// `outside-click` reaches a hermetic run's toast, which watches no other
  /// app.
  ///
  /// True when the toast was up to hear it, whatever it made of it.
  @discardableResult
  func outsideClick(at location: CGPoint) -> Bool {
    guard panel?.isVisible == true, model.suggestion != nil else { return false }
    handleClick(at: location, onToast: false)
    return true
  }

  private func handleClick(at location: CGPoint, onToast: Bool) {
    guard let panel, panel.isVisible, let suggestion = model.suggestion else { return }
    let click = ToastClick(
      onToast: onToast,
      location: location,
      menuBarItems: NSApp.windows.filter(\.holdsStatusBarButton).map(\.frame)
    )
    guard click.dismissesToast(talkBack: model.talkBack) else { return }
    onAction?(suggestion.id, .dismissed)
  }

  /// Re-fits the panel after its content changed size (expand, collapse, a
  /// transcript growing), keeping its top-right corner where it is.
  private func relayout() {
    guard let panel, panel.isVisible else { return }
    place(panel, on: panel.screen ?? NSScreen.main)
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: CGRect(x: 0, y: 0, width: ToastController.panelWidth, height: 120),
      styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.isMovableByWindowBackground = true
    panel.setAccessibilityTitle("Athina suggestion")
    panel.setAccessibilitySubrole(.floatingWindow)

    let view = ToastView(
      model: model,
      onAction: { [weak self] feedback in
        guard let self, let suggestion = self.model.suggestion else { return }
        self.onAction?(suggestion.id, feedback)
      },
      onHover: { [weak self] hovering in
        self?.onHover?(hovering)
      },
      onSizeChange: { [weak self] in
        self?.relayout()
      }
    )
    let hosting = NSHostingView(rootView: view)
    hosting.sizingOptions = [.intrinsicContentSize]
    panel.contentView = hosting
    self.hosting = hosting
    self.panel = panel
    return panel
  }

  /// Top right of the screen, just under the menu bar.
  ///
  /// The width is the toast's fixed width; only the height comes from the
  /// content, and a degenerate reading mid-update (SwiftUI can report zero
  /// while it re-lays out) keeps the frame it had, so the panel never jumps off
  /// the edge of the screen while its content changes.
  private func place(_ panel: NSPanel, on screen: NSScreen?) {
    guard let screen else { return }
    panel.contentView?.layoutSubtreeIfNeeded()
    let fitted = panel.contentView?.fittingSize ?? .zero
    guard fitted.height >= 40 else { return }
    let size = CGSize(width: ToastController.panelWidth, height: fitted.height)
    let frame = screen.visibleFrame
    let origin = CGPoint(
      x: frame.maxX - size.width - ToastController.margin,
      y: frame.maxY - size.height - ToastController.margin
    )
    panel.setFrame(CGRect(origin: origin, size: size), display: true)
  }
}

extension NSWindow {
  /// True for a menu bar item's window, the only kind that holds a status
  /// bar button. `NSApp.windows` lists only Athina's own, so its frame is
  /// Athina's item, as tall as the menu bar.
  fileprivate var holdsStatusBarButton: Bool {
    var views = contentView.map { [$0] } ?? []
    while let view = views.popLast() {
      if view is NSStatusBarButton { return true }
      views.append(contentsOf: view.subviews)
    }
    return false
  }
}

extension TalkBackState {
  fileprivate var isListening: Bool {
    if case .listening = self { return true }
    return false
  }

  fileprivate var isThinking: Bool {
    if case .thinking = self { return true }
    return false
  }
}

/// The toast's content, observable so Tell Me More, the exchange, and the
/// listening state can change in place.
@MainActor
@Observable
final class ToastModel {
  var suggestion: Suggestion?
  var expanded = false
  /// The talk-back exchange about the suggestion, oldest first.
  var exchange: [FollowUp] = []
  var talkBack: TalkBackState = .idle
  /// A short line for the user, inside the toast or on its own.
  var note: String?
  /// The talk-back hotkey, shown in the button bar once it is set and voice is usable.
  var talkBackKey: String?
}

/// The toast on its Liquid Glass surface.
///
/// Its corners are concentric with the small capsule buttons inset from its
/// bottom corners, the way system glass containers relate to the controls
/// inside them.
struct ToastView: View {
  /// Space between the glass edge and the content.
  static let inset: CGFloat = 14
  /// Half the height of a small push button, whose capsule sits `inset`
  /// in from the corner.
  static let cornerRadius: CGFloat = inset + 10

  @Bindable var model: ToastModel
  let onAction: (SuggestionFeedback) -> Void
  var onHover: (Bool) -> Void = { _ in }
  var onSizeChange: @MainActor @Sendable () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let suggestion = model.suggestion {
        ToastContent(
          suggestion: suggestion,
          expanded: model.expanded,
          exchange: model.exchange,
          talkBack: model.talkBack,
          note: model.note,
          talkBackKey: model.talkBackKey,
          onToggle: {
            // Expanding reports "tell me more"; AppState records it once
            // per suggestion, so folding back and forth is only a view change.
            let wasExpanded = model.expanded
            model.expanded.toggle()
            if !wasExpanded { onAction(.tellMeMore) }
          },
          onAction: onAction
        )
      } else if let note = model.note {
        ToastNote(text: note)
      }
    }
    .frame(width: ToastController.width)
    .glassEffect(.regular, in: .rect(cornerRadius: ToastView.cornerRadius))
    .padding(1)
    .onHover(perform: onHover)
    .onGeometryChange(for: CGSize.self) { proxy in
      proxy.size
    } action: { _ in
      onSizeChange()
    }
  }
}

/// A line on its own, for a key press with nothing to reply to.
struct ToastNote: View {
  let text: String

  var body: some View {
    Label {
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "mic.slash")
        .foregroundStyle(.secondary)
    }
    .font(.callout)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(ToastView.inset)
  }
}

/// The toast body, also used by snapshots.
///
/// The header and body sit on top, the explanation grows between them and the
/// button bar when expanded (scrolling past a sensible height), the talk-back
/// exchange and listening row sit under that, and the button bar is pinned to
/// the bottom edge with the same three buttons in every state.
struct ToastContent: View {
  static let explanationMaxHeight: CGFloat = 300
  static let exchangeMaxHeight: CGFloat = 220

  let suggestion: Suggestion
  let expanded: Bool
  var exchange: [FollowUp] = []
  var talkBack: TalkBackState = .idle
  var note: String?
  var talkBackKey: String?
  let onToggle: () -> Void
  let onAction: (SuggestionFeedback) -> Void

  private let inset = ToastView.inset

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: suggestion.category.symbol)
            .font(.title3)
            .foregroundStyle(.tint)
            .frame(width: 28, height: 28)
            .background(.tint.quaternary, in: Circle())
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            // No system notification chrome names the source, so the toast does.
            Text(
              """
              \(Text("Athina").fontWeight(.semibold)) · \(suggestion.category.label) in \
              \(suggestion.appName)
              """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityLabel("Athina, \(suggestion.category.label) in \(suggestion.appName)")
            Text(suggestion.title)
              .font(.headline)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityAddTraits(.isHeader)
          }
          Spacer(minLength: 0)
          Button {
            onAction(.dismissed)
          } label: {
            Label("Close", systemImage: "xmark")
              .labelStyle(.iconOnly)
          }
          .buttonStyle(.bordered)
          .buttonBorderShape(.circle)
          .controlSize(.small)
          .help("Close")
        }
        Text(suggestion.body)
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(inset)

      if expanded {
        Divider()
          .padding(.horizontal, inset)
        FittedScrollView(maxHeight: ToastContent.explanationMaxHeight) {
          Text(suggestion.explanation)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset)
            .padding(.vertical, 10)
        }
      }

      if !exchange.isEmpty || talkBack != .idle {
        Divider()
          .padding(.horizontal, inset)
        FittedScrollView(maxHeight: ToastContent.exchangeMaxHeight, anchor: .bottom) {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(exchange) { entry in
              ExchangeEntry(entry: entry)
            }
            switch talkBack {
            case .idle:
              EmptyView()
            case .listening(let partial):
              ListeningRow(partial: partial)
            case .waiting(let question):
              ThinkingRow(
                question: question,
                status: "Your question is next, once Athina finishes another call."
              )
            case .thinking(let question):
              ThinkingRow(question: question, status: "Asking the mentor…")
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, inset)
          .padding(.vertical, 10)
        }
      }

      if let note {
        Label(note, systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, inset)
          .padding(.bottom, 8)
      }

      HStack(spacing: 8) {
        Button(expanded ? "Show Less" : "Tell Me More", action: onToggle)
          .buttonStyle(.borderedProminent)
        Button("Not Now") { onAction(.notNow) }
          .help(
            """
            Hide \(suggestion.category.label.lowercased()) suggestions in \
            \(suggestion.appName) for a while
            """
          )
        Button("Never for This") { onAction(.never) }
          .help(
            "Stop \(suggestion.category.label.lowercased()) suggestions in \(suggestion.appName)"
          )
        Spacer(minLength: 4)
        if let talkBackKey {
          Label(talkBackKey, systemImage: "mic")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help("Hold \(talkBackKey) to talk back")
            .accessibilityLabel("Hold \(talkBackKey) to talk back")
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .padding([.horizontal, .bottom], inset)
      .padding(.top, expanded || !exchange.isEmpty || talkBack != .idle || note != nil ? 10 : 0)
    }
  }
}

/// A scroll view as tall as its content up to `maxHeight`, then scrolling.
///
/// A plain `ScrollView` inside a panel that sizes to fit keeps whatever height
/// it had, so an answer that arrives later would be cut off instead of growing
/// the toast.
private struct FittedScrollView<Content: View>: View {
  let maxHeight: CGFloat
  var anchor: UnitPoint = .top
  @ViewBuilder let content: Content
  @State private var contentHeight: CGFloat = 0

  var body: some View {
    ScrollView {
      content
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.height
        } action: { height in
          contentHeight = height
        }
    }
    .defaultScrollAnchor(anchor)
    .scrollDisabled(contentHeight <= maxHeight)
    .frame(height: min(max(contentHeight, 1), maxHeight))
  }
}

/// One question and its answer in the toast's exchange area.
private struct ExchangeEntry: View {
  let entry: FollowUp

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ExchangeLine(speaker: "You", text: entry.question, secondary: true)
      if let answer = entry.answer {
        ExchangeLine(speaker: "Athina", text: answer, secondary: false)
      } else {
        ExchangeLine(
          speaker: "Athina",
          text: "No answer: \(entry.error ?? "unknown error").",
          secondary: true
        )
      }
    }
  }
}

private struct ExchangeLine: View {
  let speaker: String
  let text: String
  let secondary: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(speaker)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 44, alignment: .trailing)
      Text(text)
        .font(.callout)
        .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }
}

/// The key is held: a pulsing microphone and the transcript so far.
struct ListeningRow: View {
  let partial: String

  @Environment(\.drawsStill)
  private var drawsStill

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "mic.fill")
        .font(.callout)
        .foregroundStyle(.red)
        .symbolEffect(.pulse, options: .repeating, isActive: !drawsStill)
        .frame(width: 44, alignment: .trailing)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("Listening…")
          .font(.callout.weight(.medium))
        Text(
          partial.isEmpty
            ? "Say \"tell me more,\" \"not now,\" or \"never for this,\" or ask a question."
            : partial
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }
}

/// The key was released and the question is with the mentor model, or
/// waiting for its current call to return.
struct ThinkingRow: View {
  let question: String
  let status: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ExchangeLine(speaker: "You", text: question, secondary: true)
      HStack(alignment: .center, spacing: 8) {
        ProgressView()
          .controlSize(.small)
          .frame(width: 44, alignment: .trailing)
          .accessibilityHidden(true)
        Text(status)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
