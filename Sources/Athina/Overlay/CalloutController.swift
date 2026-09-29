import AppKit
import AthinaCore
import CoreGraphics
import SwiftUI

/// Owns the callout overlay: a transparent, click-through, non-activating panel
/// above normal windows that frames the spot a suggestion is about, marked
/// with its note's kind; the note under the menu bar says what it points at.
///
/// It never takes focus and never sees a click, key, or scroll;
/// `ignoresMouseEvents` passes everything to whatever is under it, so VoiceOver
/// never visits it either: it hears the note when the callout appears. Deciding
/// whether the spot is still valid is `AppState`'s job with `CalloutAnchor`;
/// this only draws and removes.
@MainActor
final class CalloutController {
  private var panel: NSPanel?
  private var hosting: NSHostingView<CalloutView>?
  private(set) var placement: CalloutPlacement?
  /// Told what the callout outlines when it appears or moves, and nil when it
  /// goes, so the note can say what is outlined: the callout draws no words.
  var onChange: ((String?) -> Void)?

  var isVisible: Bool { panel?.isVisible ?? false }

  /// Draws the callout for the placement on the display it names, marked as a
  /// note of `kind`.
  func show(_ placement: CalloutPlacement, kind: NoteKind) {
    guard let display = NSScreen.screens.first(where: { $0.displayID == placement.displayID })
    else { return }
    let layout = CalloutLayout(
      screenRect: placement.screenRect,
      display: NSScreen.displayBounds(of: display)
    )
    let view = CalloutView(layout: layout, kind: kind, note: placement.note)
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
      Announce.post("Outlined on screen: \(placement.note)")
      // A short fade, which Reduce Motion leaves alone: it moves nothing.
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        panel.animator().alphaValue = 1
      }
    }
    self.placement = placement
    onChange?(placement.note)
  }

  func dismiss() {
    let wasShown = placement != nil
    placement = nil
    panel?.orderOut(nil)
    if wasShown { onChange?(nil) }
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

/// The frame around the spot: a halo, then the pointer's stroke over a faint
/// fill, with the note's own kind tile on the top-left corner, which pairs the
/// spot with its note without covering a word of what is around it.
///
/// The stroke is the pointer colour, never the accent, so it can never read as
/// the other app's keyboard focus ring. Increase Contrast thickens the stroke
/// and makes the halo solid.
struct CalloutView: View {
  static let cornerRadius: CGFloat = 6
  /// The tile's size on the corner, smaller than the note's own.
  static let tileSize: CGFloat = 16

  @Environment(\.colorSchemeContrast)
  private var contrast

  let layout: CalloutLayout
  let kind: NoteKind
  /// What the note calls the spot, which VoiceOver reads for the callout.
  let note: String

  private var box: CGRect { layout.box }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: CalloutView.cornerRadius, style: .continuous)
    let stroke: CGFloat = contrast == .increased ? 3 : 2
    ZStack(alignment: .topLeading) {
      Color.clear
      shape.fill(AthinaColor.pointerFill)
        .overlay(shape.strokeBorder(AthinaColor.pointerHalo, lineWidth: stroke + 3))
        .overlay(shape.inset(by: 1.5).strokeBorder(AthinaColor.pointer, lineWidth: stroke))
        .frame(width: box.width, height: box.height)
        .offset(x: box.minX, y: box.minY)
      KindTile(kind: kind, size: CalloutView.tileSize)
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
        .offset(
          x: box.minX - CalloutView.tileSize / 2,
          y: box.minY - CalloutView.tileSize / 2
        )
    }
    .frame(width: layout.windowRect.width, height: layout.windowRect.height, alignment: .topLeading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Athina callout, \(kind.label.lowercased()): \(note)")
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
