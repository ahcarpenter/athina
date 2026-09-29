import AppKit
import AthinaCore
import SwiftUI

/// Athina's own colours beyond its accent, each resolved per appearance and
/// for Increase Contrast the way an asset-catalog colour is.
///
/// The accent is `AccentColor` in `Resources/Assets.xcassets`, because AppKit
/// reads it from there; these are drawn only by Athina's own views, so they
/// live here and a test process draws them too. Text, backgrounds and status
/// are the system's colours, never these.
enum AthinaColor {
  /// The callout's stroke: Athina pointing at a spot in another app's window.
  ///
  /// Deliberately not the accent, so it can never read as that app's keyboard
  /// focus ring, whichever accent the person picked. One mid-tone teal clears
  /// 3:1 against both a white page and a dark editor.
  static let pointer = dynamic(
    light: (0x38948A, 1),
    dark: (0x38948A, 1),
    lightHighContrast: (0x096058, 1),
    darkHighContrast: (0x87C5BD, 1)
  )
  /// The faint tint inside the callout, so the spot reads as marked.
  static let pointerFill = dynamic(
    light: (0x38948A, 0.12),
    dark: (0x38948A, 0.16),
    lightHighContrast: (0x38948A, 0.12),
    darkHighContrast: (0x38948A, 0.16)
  )
  /// The halo around the pointer's stroke, so it stays visible over content
  /// of any colour.
  static let pointerHalo = dynamic(
    light: (0xFFFFFF, 0.85),
    dark: (0x000000, 0.6),
    lightHighContrast: (0xFFFFFF, 1),
    darkHighContrast: (0x000000, 1)
  )

  /// A kind's tile: colour lives in the tile, never in the words beside it.
  static func tile(_ kind: NoteKind) -> Color {
    switch kind {
    case .fasterWay: fasterWay
    case .risk: risk
    case .deadEnd: deadEnd
    }
  }

  /// The glyph on a tile: white clears 3:1 on every tile colour.
  static let onTile = Color.white

  private static let fasterWay = dynamic(
    light: (0x11746B, 1),
    dark: (0x38948A, 1),
    lightHighContrast: (0x096058, 1),
    darkHighContrast: (0x11746B, 1)
  )
  private static let risk = dynamic(
    light: (0xD55C13, 1),
    dark: (0xD55C13, 1),
    lightHighContrast: (0xBA4D00, 1),
    darkHighContrast: (0xBA4D00, 1)
  )
  private static let deadEnd = dynamic(
    light: (0x505BA7, 1),
    dark: (0x6874BB, 1),
    lightHighContrast: (0x46509A, 1),
    darkHighContrast: (0x505BA7, 1)
  )

  private typealias Value = (rgb: UInt32, alpha: Double)

  private static func dynamic(
    light: Value,
    dark: Value,
    lightHighContrast: Value,
    darkHighContrast: Value
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let value: Value =
          switch appearance.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
          ])
          {
          case .darkAqua: dark
          case .accessibilityHighContrastAqua: lightHighContrast
          case .accessibilityHighContrastDarkAqua: darkHighContrast
          default: light
          }
        return NSColor(
          srgbRed: CGFloat((value.rgb >> 16) & 0xFF) / 255,
          green: CGFloat((value.rgb >> 8) & 0xFF) / 255,
          blue: CGFloat(value.rgb & 0xFF) / 255,
          alpha: value.alpha
        )
      }
    )
  }
}

/// A kind's tile, the way System Settings marks its panes: a coloured rounded
/// square with a white symbol, always beside the kind's name in words, so a
/// kind is never told by colour alone.
struct KindTile: View {
  let kind: NoteKind
  var size: CGFloat = 22

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
      .fill(AthinaColor.tile(kind).gradient)
      .frame(width: size, height: size)
      .overlay {
        Image(systemName: kind.symbol)
          .font(.system(size: size * 0.52, weight: .semibold))
          .foregroundStyle(AthinaColor.onTile)
      }
      .accessibilityHidden(true)
  }
}
