import AppKit
import AthinaCore
import Foundation

/// Loads the menu bar mark's variants from the bundle.
///
/// Each variant is a PDF, so one file serves every display scale, and each is
/// a template image, so macOS tints it with the menu bar's own foreground
/// colour like every other extra rather than drawing it in a colour of its
/// own. They are built from `Resources/Mark/AthinaOwl.svg` by
/// `scripts/mark-assets.swift` (`make mark`).
@MainActor
enum MenuBarMarkImage {
  private static var loaded: [MenuBarMark: NSImage] = [:]

  /// The folder the variants are read from: the app bundle's resources.
  ///
  /// The UI smoke test runs in a test process, whose bundle is the test
  /// runner's, so it points this at `Resources/Mark`, where `make mark` writes
  /// them.
  static var directory = Bundle.main.resourceURL

  static func image(for mark: MenuBarMark) -> NSImage? {
    if let found = loaded[mark] { return found }
    guard let url = directory?.appendingPathComponent("MenuBarMark-\(mark.rawValue).pdf"),
      let image = NSImage(contentsOf: url)
    else { return nil }
    image.isTemplate = true
    image.accessibilityDescription = nil
    loaded[mark] = image
    return image
  }
}
