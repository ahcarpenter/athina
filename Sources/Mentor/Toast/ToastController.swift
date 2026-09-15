import AppKit
import MentorCore
import SwiftUI

/// Owns the floating suggestion panel: a non-activating window that never
/// takes keyboard focus, placed under the menu bar at the top right of the
/// screen the user is working on. With no suggestion up it can show a short
/// note instead, for a talk-back key press that has nothing to reply to.
@MainActor
final class ToastController {
    static let width: CGFloat = 380
    static let margin: CGFloat = 12
    static let noteDuration: TimeInterval = 4

    var onAction: ((Int64, SuggestionFeedback) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onSpeakToggle: (() -> Void)?

    private var panel: NSPanel?
    private var hosting: NSHostingView<ToastView>?
    private var model = ToastModel()
    private var outsideClickMonitors: [Any] = []
    private var noteTask: Task<Void, Never>?

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
    }

    /// While the user is talking back the toast stays where it is: it is
    /// brought to the front so no window covers it, and no click, timeout,
    /// or hover can take it down until the exchange is over.
    func setTalkBack(_ state: TalkBackState) {
        model.talkBack = state
        if state.keepsToastUp {
            bringToFront()
        }
    }

    func setExchange(_ exchange: [FollowUp]) {
        model.exchange = exchange
    }

    func setSpeaking(_ speaking: Bool) {
        model.isSpeaking = speaking
    }

    func setSpeechAllowed(_ allowed: Bool) {
        model.speechAllowed = allowed
    }

    func setTalkBackKey(_ key: String?) {
        model.talkBackKey = key
    }

    /// A short line for the user: inside the toast when a suggestion is up,
    /// otherwise as a small panel of its own. It clears itself.
    func showNote(_ text: String) {
        noteTask?.cancel()
        model.note = text
        if model.suggestion == nil {
            present()
        }
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ToastController.noteDuration))
            guard !Task.isCancelled, let self, self.model.note == text else { return }
            self.model.note = nil
            if self.model.suggestion == nil {
                self.panel?.orderOut(nil)
            }
        }
    }

    private func present() {
        let panel = panel ?? makePanel()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        place(panel, on: screen)
        panel.orderFrontRegardless()
    }

    // MARK: Outside clicks

    /// A mouse-down anywhere but the toast dismisses it, the way a macOS
    /// notification banner goes away when you click elsewhere. The global
    /// monitor sees clicks in other apps and on the desktop, which carry no
    /// window of ours; the local one sees clicks in Mentor's own windows and
    /// passes every event through, so only an event aimed at the toast's own
    /// panel keeps it up and its buttons still work. Only mouse-down is watched,
    /// so scrolling, typing, and moving the pointer leave the toast alone.
    /// Neither monitor makes the panel key or activates the app.
    private func startWatchingForOutsideClicks() {
        guard outsideClickMonitors.isEmpty else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleClick(event) }
        }) {
            outsideClickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleClick(event) }
            return event
        }) {
            outsideClickMonitors.append(local)
        }
    }

    private func stopWatchingForOutsideClicks() {
        for monitor in outsideClickMonitors { NSEvent.removeMonitor(monitor) }
        outsideClickMonitors.removeAll()
    }

    private func handleClick(_ event: NSEvent) {
        guard let panel, panel.isVisible, event.window !== panel else { return }
        guard let suggestion = model.suggestion else { return }
        // A click elsewhere while the user is talking back is part of what
        // they are doing, not an answer to the toast.
        guard !model.talkBack.keepsToastUp else { return }
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
            contentRect: CGRect(x: 0, y: 0, width: ToastController.width, height: 120),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        panel.isMovableByWindowBackground = true
        panel.setAccessibilityTitle("Mentor suggestion")

        let view = ToastView(model: model, onAction: { [weak self] feedback in
            guard let self, let suggestion = self.model.suggestion else { return }
            self.onAction?(suggestion.id, feedback)
        }, onHover: { [weak self] hovering in
            self?.onHover?(hovering)
        }, onSpeakToggle: { [weak self] in
            self?.onSpeakToggle?()
        }, onSizeChange: { [weak self] in
            self?.relayout()
        })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel
        return panel
    }

    /// Top right of the screen, just under the menu bar.
    private func place(_ panel: NSPanel, on screen: NSScreen?) {
        guard let screen else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? CGSize(width: ToastController.width, height: 120)
        let frame = screen.visibleFrame
        let origin = CGPoint(
            x: frame.maxX - size.width - ToastController.margin,
            y: frame.maxY - size.height - ToastController.margin
        )
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

/// The toast's content, observable so "Tell me more", the exchange, and the
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
    var isSpeaking = false
    /// False while speech is gated off (paused, idle, excluded app).
    var speechAllowed = true
    /// The talk-back hotkey, shown in the button bar once it is set and voice is usable.
    var talkBackKey: String?
}

struct ToastView: View {
    @Bindable var model: ToastModel
    let onAction: (SuggestionFeedback) -> Void
    var onHover: (Bool) -> Void = { _ in }
    var onSpeakToggle: () -> Void = {}
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
                    isSpeaking: model.isSpeaking,
                    speechAllowed: model.speechAllowed,
                    talkBackKey: model.talkBackKey,
                    onToggle: {
                        // Expanding reports "tell me more"; AppState records it once
                        // per suggestion, so folding back and forth is only a view change.
                        let wasExpanded = model.expanded
                        model.expanded.toggle()
                        if !wasExpanded { onAction(.tellMeMore) }
                    },
                    onAction: onAction,
                    onSpeakToggle: onSpeakToggle
                )
            } else if let note = model.note {
                ToastNote(text: note)
            }
        }
        .frame(width: ToastController.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
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
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "mic.slash")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

/// The toast body, also used by snapshots. The header and body sit on top,
/// the explanation grows between them and the button bar when expanded
/// (scrolling past a sensible height), the talk-back exchange and listening
/// row sit under that, and the button bar is pinned to the bottom edge with
/// the same three buttons in every state.
struct ToastContent: View {
    static let explanationMaxHeight: CGFloat = 300
    static let exchangeMaxHeight: CGFloat = 220

    let suggestion: Suggestion
    let expanded: Bool
    var exchange: [FollowUp] = []
    var talkBack: TalkBackState = .idle
    var note: String?
    var isSpeaking = false
    var speechAllowed = true
    var talkBackKey: String?
    let onToggle: () -> Void
    let onAction: (SuggestionFeedback) -> Void
    var onSpeakToggle: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: suggestion.category.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 24, height: 24)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("Mentor")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text("\(suggestion.category.label) in \(suggestion.appName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(suggestion.title)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button(action: onSpeakToggle) {
                        Image(systemName: isSpeaking ? "stop.circle" : "speaker.wave.2.fill")
                            .font(.system(size: isSpeaking ? 13 : 11, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(isSpeaking ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .disabled(!speechAllowed)
                    .help(speakHelp)
                    .accessibilityLabel(isSpeaking ? "Stop speaking" : "Speak this suggestion")
                    Button {
                        onAction(.dismissed)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Close")
                    .accessibilityLabel("Close")
                }
                Text(suggestion.body)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)

            if expanded {
                Divider()
                    .padding(.horizontal, 14)
                FittedScrollView(maxHeight: ToastContent.explanationMaxHeight) {
                    Text(suggestion.explanation)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }

            if !exchange.isEmpty || talkBack != .idle {
                Divider()
                    .padding(.horizontal, 14)
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
                        case .thinking(let question):
                            ThinkingRow(question: question)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }

            if let note {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Divider()
            HStack(spacing: 8) {
                Button(expanded ? "Show less" : "Tell me more", action: onToggle)
                    .buttonStyle(.borderedProminent)
                Button("Not now") { onAction(.notNow) }
                    .buttonStyle(.bordered)
                Button("Never for this") { onAction(.never) }
                    .buttonStyle(.bordered)
                    .help("Stop \(suggestion.category.label.lowercased()) suggestions in \(suggestion.appName)")
                Spacer(minLength: 4)
                if let talkBackKey {
                    Label(talkBackKey, systemImage: "mic")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help("Hold \(talkBackKey) to talk back")
                        .accessibilityLabel("Hold \(talkBackKey) to talk back")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var speakHelp: String {
        if isSpeaking { return "Stop speaking" }
        if !speechAllowed { return "Nothing is spoken while Mentor is paused, idle, or on an excluded app" }
        return "Speak this suggestion"
    }
}

/// A scroll view as tall as its content up to `maxHeight`, then scrolling.
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
                ExchangeLine(speaker: "Mentor", text: answer, secondary: false)
            } else {
                ExchangeLine(speaker: "Mentor", text: "No answer: \(entry.error ?? "unknown error").", secondary: true)
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
    }
}

/// The key is held: a pulsing microphone and the transcript so far.
struct ListeningRow: View {
    let partial: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
                .frame(width: 44, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text("Listening…")
                    .font(.callout.weight(.medium))
                Text(partial.isEmpty ? "Say \"tell me more\", \"not now\", \"never for this\", or ask a question." : partial)
                    .font(.callout)
                    .foregroundStyle(partial.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The key was released and the question is with the mentor model.
struct ThinkingRow: View {
    let question: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ExchangeLine(speaker: "You", text: question, secondary: true)
            HStack(alignment: .center, spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 44, alignment: .trailing)
                Text("Mentor is thinking…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
