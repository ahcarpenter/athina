import AppKit
import AthinaCore
import SwiftUI

/// Owns the callout overlay: a transparent, click-through, non-activating panel
/// above normal windows that frames the spot a suggestion is about and shows
/// its note beside it.
///
/// It never takes focus and never sees a click, key, or scroll;
/// `ignoresMouseEvents` passes everything to whatever is under it. Deciding
/// whether the spot is still valid is `AppState`'s job with `CalloutAnchor`;
/// this only draws and removes.
@MainActor
final class CalloutController {
  private var panel: NSPanel?
  private var hosting: NSHostingView<CalloutView>?
  private(set) var placement: CalloutPlacement?

  var isVisible: Bool { panel?.isVisible ?? false }

  /// Draws the callout for the placement on the display it names.
  func show(_ placement: CalloutPlacement) {
    guard let display = NSScreen.screens.first(where: { $0.displayID == placement.displayID })
    else { return }
    let layout = CalloutLayout(
      screenRect: placement.screenRect,
      display: NSScreen.displayBounds(of: display)
    )
    let view = CalloutView(layout: layout, note: placement.note)
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
      // A short fade, which Reduce Motion leaves alone: it moves nothing.
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
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.animationBehavior = .none
    panel.isMovableByWindowBackground = false
    panel.setAccessibilityTitle("Athina callout")
    self.panel = panel
    return panel
  }
}

/// The highlight box and its note, styled like the toast: an accent-colored
/// rounded stroke with a soft glow around the spot, and the note on the same
/// Liquid Glass as the toast.
///
/// Increase Contrast thickens the stroke and drops the glow for a crisp edge.
struct CalloutView: View {
  static let cornerRadius: CGFloat = 8

  @Environment(\.colorSchemeContrast) private var contrast

  let layout: CalloutLayout
  let note: String

  private var box: CGRect { layout.box }

  /// Beside the box the pill is centred on it; below or above, it hugs the box.
  private var noteAlignment: Alignment {
    switch layout.notePlacement {
    case .trailing: .leading
    case .below: .topLeading
    case .above: .bottomLeading
    }
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      Color.clear
      RoundedRectangle(cornerRadius: CalloutView.cornerRadius, style: .continuous)
        .strokeBorder(.tint, lineWidth: contrast == .increased ? 3.5 : 2.5)
        .background(
          RoundedRectangle(cornerRadius: CalloutView.cornerRadius, style: .continuous)
            .fill(.tint.opacity(0.06))
        )
        .shadow(color: Color.accentColor.opacity(contrast == .increased ? 0 : 0.55), radius: 6)
        .frame(width: box.width, height: box.height)
        .offset(x: box.minX, y: box.minY)
      notePill
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: layout.noteRect.width, alignment: .leading)
        .frame(
          width: layout.noteRect.width,
          height: layout.noteRect.height,
          alignment: noteAlignment
        )
        .offset(x: layout.noteRect.minX, y: layout.noteRect.minY)
    }
    .frame(width: layout.windowRect.width, height: layout.windowRect.height, alignment: .topLeading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Athina callout: \(note)")
  }

  private var notePill: some View {
    Label {
      Text(note)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "lightbulb.fill")
        .foregroundStyle(.tint)
    }
    .font(.callout.weight(.medium))
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .glassEffect(.regular, in: .rect(cornerRadius: CalloutView.cornerRadius + 6))
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
