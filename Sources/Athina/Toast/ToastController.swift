import AppKit
import AthinaCore
import CoreGraphics
import Foundation
import Observation
import SwiftUI

/// Owns the floating suggestion panel: a non-activating window that never takes
/// keyboard focus, placed under the menu bar at the top right of the screen the
/// user is working on.
///
/// With no suggestion up it can show a short note instead, for a talk-back key
/// press that has nothing to reply to or an answer's consequence.
///
/// Because the panel never becomes key, VoiceOver hears about it through
/// announcements, and the menu bar menu offers its answers to the keyboard.
/// A person may drag it off what it covers, and it stays where they put it
/// until the next suggestion (`ToastPlacement`).
@MainActor
final class ToastController {
  static let width: CGFloat = 380
  /// The panel is the toast plus a point on each side, so the glass edge is
  /// never clipped by the window.
  static let panelWidth: CGFloat = width + 2
  static let margin: CGFloat = 12
  /// The panel's title while it shows a suggestion, which VoiceOver reads and
  /// the control API finds the toast by.
  static let suggestionTitle = "Athina suggestion"
  /// The panel's title while it shows only a note.
  static let noteTitle = "Athina note"

  var onAction: ((Int64, SuggestionFeedback) -> Void)?
  var onHover: ((Bool) -> Void)?

  private var panel: NSPanel?
  private var hosting: NSHostingView<ToastPanelRoot>?
  private var model = ToastModel()
  private var outsideClickMonitors: [Any] = []
  private var noteTask: Task<Void, Never>?
  /// The note's time on screen, held while the pointer is over the panel.
  private var noteCountdown = ToastCountdown()
  /// Whether the note stays until the next click rather than timing out:
  /// one that names a next step.
  private var noteUntilClicked = false
  private var pointerOverPanel = false
  /// Where the person dragged the panel to, its top-left corner, until the
  /// next suggestion.
  private var movedTopLeft: CGPoint?
  /// Set when the person starts dragging the panel, so the move that follows
  /// is told apart from the panel's own placement.
  private var movedByPerson = false
  private var moveObservers: [NSObjectProtocol] = []
  /// Whether the toast has told VoiceOver once where its answers are.
  private var saidWhereAnswersAre = false
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

  /// Shows a suggestion.
  ///
  /// - Parameters:
  ///   - suggestion: The suggestion to show.
  ///   - expanded: Whether it opens with its explanation showing.
  ///   - exchange: The talk-back exchange about it so far.
  ///   - asked: Whether the person asked for it, as Show Last Suggestion
  ///     does. One they did not ask for arrives while they are busy, so
  ///     VoiceOver hears it after what it is saying rather than over it.
  func show(_ suggestion: Suggestion, expanded: Bool, exchange: [FollowUp], asked: Bool = false) {
    clearNote()
    if model.suggestion?.id != suggestion.id {
      movedTopLeft = nil
    }
    model.suggestion = suggestion
    model.expanded = expanded
    model.exchange = exchange
    model.talkBack = .idle
    present()
    startWatchingForOutsideClicks()
    var announcement = ToastController.announcement(for: suggestion)
    if !saidWhereAnswersAre {
      saidWhereAnswersAre = true
      announcement += " Answer it from the Athina menu."
    }
    Announce.post(announcement, priority: asked ? .high : .medium)
  }

  /// What VoiceOver hears for a suggestion: what the header, title and body
  /// show.
  static func announcement(for suggestion: Suggestion) -> String {
    """
    Athina, \(suggestion.category.label) in \(suggestion.appName): \(suggestion.title). \
    \(suggestion.body)
    """
  }

  func dismiss() {
    stopWatchingForOutsideClicks()
    clearNote()
    model.suggestion = nil
    model.exchange = []
    model.talkBack = .idle
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
      Announce.post(suggestion.explanation, priority: .high)
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
      Announce.post("Listening")
    case .thinking where !previous.isThinking:
      Announce.post("Asking the mentor")
    case .idle, .listening, .waiting, .thinking:
      break
    }
  }

  func setExchange(_ exchange: [FollowUp]) {
    if let latest = exchange.last,
      latest.id != model.exchange.last?.id || latest.answer != model.exchange.last?.answer
    {
      Announce.post(
        latest.answer.map { "Athina answered: \($0)" } ?? ExchangeEntry.failure(latest),
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
  /// It clears itself once there has been time to read it
  /// (`ToastPlacement.noteDuration`), a time that stands still while the
  /// pointer is over it.
  ///
  /// - Parameters:
  ///   - text: What the note says.
  ///   - untilClicked: For a note that names a next step: it stays until the
  ///     next click, anywhere, instead of timing out.
  func showNote(_ text: String, untilClicked: Bool = false) {
    clearNote()
    model.note = text
    noteUntilClicked = untilClicked
    if model.suggestion == nil {
      present()
      if untilClicked { startWatchingForOutsideClicks() }
    }
    Announce.post(text)
    guard !untilClicked else { return }
    noteCountdown.run(for: ToastPlacement.noteDuration(for: text), from: clock.date)
    if pointerOverPanel {
      noteCountdown.hold(at: clock.date)
    } else {
      waitOutNote()
    }
  }

  /// The note on screen, if any.
  var note: String? { model.note }

  /// Clears the note when its countdown runs out, unless the countdown was
  /// held or run again meanwhile.
  private func waitOutNote() {
    guard let deadline = noteCountdown.deadline else { return }
    noteTask?.cancel()
    let clock = clock
    noteTask = Task { [weak self] in
      try? await clock.sleep(untilDate: deadline)
      guard !Task.isCancelled, let self, self.noteCountdown.deadline == deadline else { return }
      self.takeDownNote()
    }
  }

  private func takeDownNote() {
    clearNote()
    if model.suggestion == nil {
      stopWatchingForOutsideClicks()
      panel?.orderOut(nil)
    }
  }

  private func clearNote() {
    noteTask?.cancel()
    noteTask = nil
    noteCountdown.cancel()
    noteUntilClicked = false
    model.note = nil
  }

  /// The pointer came over the panel or left it: a note's time stands still
  /// while it is over it, and runs on with what it had when it leaves.
  private func pointerOverPanelChanged(_ over: Bool) {
    pointerOverPanel = over
    guard model.note != nil, !noteUntilClicked else { return }
    if over {
      noteTask?.cancel()
      noteCountdown.hold(at: clock.date)
    } else if let remaining = noteCountdown.held {
      noteCountdown.run(for: remaining, from: clock.date)
      waitOutNote()
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
    panel.title =
      model.suggestion == nil ? ToastController.noteTitle : ToastController.suggestionTitle
    // New content appears at once; only the same toast growing or shrinking
    // is animated (`relayout`).
    place(panel, on: movedTopLeft == nil ? screen : panel.screen ?? screen, animated: false)
    panel.orderFrontRegardless()
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

  private func handleClick(at location: CGPoint, onToast: Bool) {
    guard let panel, panel.isVisible else { return }
    guard let suggestion = model.suggestion else {
      // A note that waits for the next click, wherever it lands.
      if noteUntilClicked { takeDownNote() }
      return
    }
    let click = ToastClick(
      onToast: onToast,
      location: location,
      menuBarItems: NSApp.windows.filter(\.holdsStatusBarButton).map(\.frame)
    )
    guard click.dismissesToast(talkBack: model.talkBack) else { return }
    onAction?(suggestion.id, .dismissed)
  }

  /// A mouse-down outside Athina's windows at `location`, in screen
  /// coordinates, as the global monitor reports one: how the control API's
  /// `outside-click` reaches a hermetic run's toast, which watches no other
  /// app.
  ///
  /// True when the toast was up to hear it, whatever it made of it.
  @discardableResult
  func outsideClick(at location: CGPoint) -> Bool {
    guard panel?.isVisible == true, model.suggestion != nil || noteUntilClicked else {
      return false
    }
    handleClick(at: location, onToast: false)
    return true
  }

  /// Re-fits the panel after its content changed size (expand, collapse, a
  /// transcript growing), keeping its top edge where it is.
  private func relayout() {
    guard let panel, panel.isVisible else { return }
    place(panel, on: panel.screen ?? NSScreen.main, animated: true)
  }

  /// Tells a move the person made by dragging the panel from the panel's own
  /// placement: only a drag sends `willMove` first.
  private func watchForMoves(of panel: NSPanel) {
    let center = NotificationCenter.default
    moveObservers = [
      center.addObserver(forName: NSWindow.willMoveNotification, object: panel, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.movedByPerson = true }
      },
      center.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.movedByPerson, let panel = self.panel else { return }
          self.movedTopLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        }
      },
    ]
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
    // The title a person never sees, since the panel has no title bar;
    // VoiceOver reads it, and the control API finds the panel by it.
    panel.title = ToastController.suggestionTitle
    panel.setAccessibilitySubrole(.floatingWindow)
    watchForMoves(of: panel)

    let view = ToastView(
      model: model,
      onAction: { [weak self] feedback in
        guard let self, let suggestion = self.model.suggestion else { return }
        self.onAction?(suggestion.id, feedback)
      },
      onHover: { [weak self] hovering in
        self?.pointerOverPanelChanged(hovering)
        self?.onHover?(hovering)
      },
      onSizeChange: { [weak self] in
        self?.relayout()
      }
    )
    let hosting = NSHostingView(rootView: ToastPanelRoot(toast: view))
    hosting.sizingOptions = [.intrinsicContentSize]
    panel.contentView = hosting
    self.hosting = hosting
    self.panel = panel
    return panel
  }

  /// Top right of the screen, just under the menu bar, or where the person
  /// dragged it (`ToastPlacement`).
  ///
  /// The width is the toast's fixed width; only the height comes from the
  /// content, and a degenerate reading mid-update (SwiftUI can report zero
  /// while it re-lays out) keeps the frame it had, so the panel never jumps off
  /// the edge of the screen while its content changes. Asked to animate, a
  /// panel already up grows or shrinks in a short animation from its top edge,
  /// its content pinned there; with Reduce Motion, or in a hermetic run, which
  /// nobody sees and whose clicks must not land mid-animation, it changes size
  /// at once.
  private func place(_ panel: NSPanel, on screen: NSScreen?, animated: Bool) {
    guard let screen else { return }
    panel.contentView?.layoutSubtreeIfNeeded()
    let fitted = panel.contentView?.fittingSize ?? .zero
    guard fitted.height >= 40 else { return }
    let frame = ToastPlacement.frame(
      size: CGSize(width: ToastController.panelWidth, height: fitted.height),
      visible: screen.visibleFrame,
      margin: ToastController.margin,
      movedTopLeft: movedTopLeft
    )
    movedByPerson = false
    guard frame != panel.frame else { return }
    if animated, watchesOtherApps, panel.isVisible,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        panel.animator().setFrame(frame, display: true)
      }
    } else {
      panel.setFrame(frame, display: true)
    }
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

/// The toast as the panel holds it: pinned to the panel's top edge, so while
/// the panel grows or shrinks around it the content stays still under the
/// pointer.
struct ToastPanelRoot: View {
  let toast: ToastView

  var body: some View {
    toast.frame(maxHeight: .infinity, alignment: .top)
  }
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
    .onGeometryChange(
      for: CGSize.self,
      of: { proxy in
        proxy.size
      },
      action: { _ in
        onSizeChange()
      }
    )
  }
}

/// A line on its own, for a key press with nothing to reply to.
struct ToastNote: View {
  let text: String

  var body: some View {
    Label(
      title: {
        Text(text)
          .fixedSize(horizontal: false, vertical: true)
      },
      icon: {
        Image(systemName: "mic.slash")
          .foregroundStyle(.secondary)
      }
    )
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

  /// What the header line says: who is speaking, and what kind of suggestion
  /// about which app.
  private var source: String { "\(suggestion.category.label) in \(suggestion.appName)" }

  /// A warning is drawn as one, in the attention color, not as a tip in the accent.
  private var discTint: Color {
    suggestion.category.isWarning ? StatusTint.attention.color : .accentColor
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: suggestion.category.symbol)
            .font(.title3)
            .foregroundStyle(discTint)
            .frame(width: 28, height: 28)
            .background(discTint.quaternary, in: Circle())
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            // No system notification chrome names the source, so the toast does.
            Text("\(Text("Athina").fontWeight(.semibold)) · \(source)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              // A long app name is cut on screen; the whole line is a hover away.
              .help("Athina · \(source)")
              .accessibilityLabel("Athina, \(source)")
            Text(suggestion.title)
              .font(.headline)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityAddTraits(.isHeader)
          }
          Spacer(minLength: 0)
          Button(
            action: {
              onAction(.dismissed)
            },
            label: {
              Label("Close", systemImage: "xmark")
                .labelStyle(.iconOnly)
            }
          )
          .buttonStyle(.bordered)
          .buttonBorderShape(.circle)
          .controlSize(.small)
          .help("Close")
          .accessibilityIdentifier("toast.close")
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
          // One grid for the whole exchange, so the speaker column is as wide
          // as its widest word rather than a fixed width.
          Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
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
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, inset)
          .padding(.bottom, 8)
      }

      HStack(spacing: 8) {
        // The one prominent button, drawn by its own style: the panel is
        // never key, and the system's prominent styles draw a button in a
        // window that is not key in the inactive grey, or faded.
        Button(expanded ? "Show Less" : "Tell Me More", action: onToggle)
          .buttonStyle(ToastProminentButtonStyle())
          .accessibilityIdentifier("toast.tellMeMore")
        Button("Not Now") { onAction(.notNow) }
          .help(notNowConsequence)
          .accessibilityHint(notNowConsequence)
          .accessibilityIdentifier("toast.notNow")
        Button("Never for This") { onAction(.never) }
          .help(neverConsequence)
          .accessibilityHint(neverConsequence)
          .accessibilityIdentifier("toast.never")
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

  private var notNowConsequence: String {
    """
    Hides \(suggestion.category.label.lowercased()) suggestions in \(suggestion.appName) \
    for a while
    """
  }

  private var neverConsequence: String {
    "Stops \(suggestion.category.label.lowercased()) suggestions in \(suggestion.appName)"
  }
}

/// The toast's prominent button: the accent capsule a small prominent push
/// button draws in an active window, drawn the same whether or not the panel
/// is key, beside small bordered buttons of the same height.
struct ToastProminentButtonStyle: ButtonStyle {
  @Environment(\.isEnabled)
  private var isEnabled

  @Environment(\.colorSchemeContrast)
  private var contrast

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline)
      .foregroundStyle(.white)
      .lineLimit(1)
      .padding(.horizontal, 10)
      .frame(minHeight: 20)
      .background(
        Capsule().fill(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1))
      )
      .overlay {
        if contrast == .increased {
          Capsule().strokeBorder(.primary.opacity(0.5))
        }
      }
      .opacity(isEnabled ? 1 : 0.5)
      .contentShape(Capsule())
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
        .onGeometryChange(
          for: CGFloat.self,
          of: { proxy in
            proxy.size.height
          },
          action: { height in
            contentHeight = height
          }
        )
    }
    .defaultScrollAnchor(anchor)
    .scrollDisabled(contentHeight <= maxHeight)
    .frame(height: min(max(contentHeight, 1), maxHeight))
  }
}

/// One question and its answer in the toast's exchange area, as two rows of
/// the exchange's grid.
struct ExchangeEntry: View {
  let entry: FollowUp

  /// What the person reads, and VoiceOver hears, for a question that got no
  /// answer: why, in Athina's own words (`UserFacing`).
  static func failure(_ entry: FollowUp) -> String {
    UserFacing.followUpError(entry.error ?? "unknown error")
  }

  var body: some View {
    ExchangeLine(speaker: "You", text: entry.question, secondary: true)
    if let answer = entry.answer {
      ExchangeLine(speaker: "Athina", text: answer, secondary: false)
    } else {
      // The code's own words stay a hover away, for a bug report.
      ExchangeLine(speaker: "Athina", text: ExchangeEntry.failure(entry), secondary: true)
        .help(entry.error ?? "")
    }
  }
}

/// A speaker and what they said, as a row of the exchange's grid, whose first
/// column sizes to its widest speaker.
private struct ExchangeLine: View {
  let speaker: String
  let text: String
  let secondary: Bool

  var body: some View {
    GridRow {
      Text(speaker)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.trailing)
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

/// The key is held: a pulsing microphone and the transcript so far, as a row
/// of the exchange's grid.
struct ListeningRow: View {
  let partial: String

  @Environment(\.drawsStill)
  private var drawsStill

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    GridRow {
      Image(systemName: "mic.fill")
        .font(.callout)
        .foregroundStyle(StatusTint.active.color)
        // With Reduce Motion the microphone holds still; the word beside it
        // says it is listening.
        .symbolEffect(.pulse, options: .repeating, isActive: !drawsStill && !reduceMotion)
        .gridColumnAlignment(.trailing)
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
/// waiting for its current call to return, as rows of the exchange's grid.
struct ThinkingRow: View {
  let question: String
  let status: String

  var body: some View {
    ExchangeLine(speaker: "You", text: question, secondary: true)
    GridRow(alignment: .center) {
      ProgressView()
        .controlSize(.small)
        .gridColumnAlignment(.trailing)
        .accessibilityHidden(true)
      Text(status)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
