import AppKit
import MentorCore
import SwiftUI

/// Owns the callout overlay: a transparent, click-through, non-activating
/// panel above normal windows that frames the spot a suggestion is about and
/// shows its note beside it. It never takes focus and never sees a click, key,
/// or scroll; `ignoresMouseEvents` passes everything to whatever is under it.
/// Deciding whether the spot is still valid is `AppState`'s job with
/// `CalloutAnchor`; this only draws and removes.
@MainActor
final class CalloutController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<CalloutView>?
    private(set) var placement: CalloutPlacement?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Draws the callout for the placement on the display it names.
    func show(_ placement: CalloutPlacement) {
        guard let display = NSScreen.screens.first(where: { $0.displayID == placement.displayID }) else { return }
        let layout = CalloutLayout(screenRect: placement.screenRect, display: NSScreen.displayBounds(of: display))
        let view = CalloutView(box: layout.box, note: placement.note, noteBelow: layout.noteBelow, size: layout.windowRect.size)
        let panel = panel ?? makePanel()
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.sizingOptions = []
            panel.contentView = hosting
            self.hosting = hosting
        }
        panel.setFrame(NSScreen.cocoaRect(fromGlobal: layout.windowRect), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }
        self.placement = placement
    }

    func dismiss() {
        placement = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.nonactivatingPanel, .borderless],
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
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.isMovableByWindowBackground = false
        panel.setAccessibilityTitle("Mentor callout")
        self.panel = panel
        return panel
    }
}

/// The highlight box and its note, styled like the toast: a tinted rounded
/// stroke with a soft glow around the spot, and a material pill for the note.
struct CalloutView: View {
    static let cornerRadius: CGFloat = 8

    let box: CGRect
    let note: String
    let noteBelow: Bool
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            RoundedRectangle(cornerRadius: CalloutView.cornerRadius, style: .continuous)
                .strokeBorder(.tint, lineWidth: 2.5)
                .background(
                    RoundedRectangle(cornerRadius: CalloutView.cornerRadius, style: .continuous)
                        .fill(.tint.opacity(0.06))
                )
                .shadow(color: Color.accentColor.opacity(0.55), radius: 6)
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
            notePill
                .fixedSize()
                .frame(maxWidth: CalloutLayout.noteMaxWidth, alignment: .leading)
                .offset(x: box.minX, y: noteBelow ? box.maxY + CalloutLayout.gap : max(0, box.minY - CalloutLayout.gap - CalloutLayout.noteHeight))
                .frame(height: CalloutLayout.noteHeight, alignment: noteBelow ? .top : .bottom)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mentor callout: \(note)")
    }

    private var notePill: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tint)
            Text(note)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}

extension NSScreen {
    /// The CoreGraphics display id behind this screen.
    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Every attached display with its bounds in global display points.
    static var currentDisplays: [DisplayBounds] {
        screens.map { DisplayBounds(id: $0.displayID, bounds: displayBounds(of: $0)) }
    }

    /// The screen's bounds in global display points, origin top-left of the
    /// main display, the space `FrameInfo.screenRect` and OCR blocks use.
    static func displayBounds(of screen: NSScreen) -> CGRect {
        CGDisplayBounds(screen.displayID)
    }

    /// Global display points to the AppKit space windows are placed in,
    /// whose origin is the bottom-left of the main display.
    static func cocoaRect(fromGlobal rect: CGRect) -> CGRect {
        let mainHeight = screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
