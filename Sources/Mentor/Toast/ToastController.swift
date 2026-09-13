import AppKit
import MentorCore
import SwiftUI

/// Owns the floating suggestion panel: a non-activating window that never
/// takes keyboard focus, placed under the menu bar at the top right of the
/// screen the user is working on.
@MainActor
final class ToastController {
    static let width: CGFloat = 380
    static let margin: CGFloat = 12

    var onAction: ((Int64, SuggestionFeedback) -> Void)?
    var onHover: ((Bool) -> Void)?

    private var panel: NSPanel?
    private var hosting: NSHostingView<ToastView>?
    private var model = ToastModel()
    private var outsideClickMonitors: [Any] = []

    func show(_ suggestion: Suggestion, expanded: Bool) {
        model.suggestion = suggestion
        model.expanded = expanded
        let panel = panel ?? makePanel()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        place(panel, on: screen)
        panel.orderFrontRegardless()
        startWatchingForOutsideClicks()
    }

    func dismiss() {
        stopWatchingForOutsideClicks()
        panel?.orderOut(nil)
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
        onAction?(suggestion.id, .dismissed)
    }

    /// Re-fits the panel after its content changed size (expand or collapse),
    /// keeping its top-right corner where it is.
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

/// The toast's content, observable so "Tell me more" can expand in place.
@MainActor
@Observable
final class ToastModel {
    var suggestion: Suggestion?
    var expanded = false
}

struct ToastView: View {
    @Bindable var model: ToastModel
    let onAction: (SuggestionFeedback) -> Void
    var onHover: (Bool) -> Void = { _ in }
    var onSizeChange: @MainActor @Sendable () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let suggestion = model.suggestion {
                ToastContent(suggestion: suggestion, expanded: model.expanded, onToggle: {
                    // Expanding reports "tell me more"; AppState records it once
                    // per suggestion, so folding back and forth is only a view change.
                    let wasExpanded = model.expanded
                    model.expanded.toggle()
                    if !wasExpanded { onAction(.tellMeMore) }
                    DispatchQueue.main.async(execute: onSizeChange)
                }, onAction: onAction)
            }
        }
        .frame(width: ToastController.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
        .padding(1)
        .onHover(perform: onHover)
    }
}

/// The toast body, also used by snapshots. The header and body sit on top,
/// the explanation grows between them and the button bar when expanded
/// (scrolling past a sensible height), and the button bar is pinned to the
/// bottom edge with the same three buttons in both states.
struct ToastContent: View {
    static let explanationMaxHeight: CGFloat = 300

    let suggestion: Suggestion
    let expanded: Bool
    let onToggle: () -> Void
    let onAction: (SuggestionFeedback) -> Void

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
                ScrollView {
                    Text(suggestion.explanation)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                .frame(maxHeight: ToastContent.explanationMaxHeight)
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
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}
