import AppKit
import MentorCore

/// Loads the menu bar mark's variants from the bundle.
///
/// Each variant is a PDF, so one file serves every display scale, and each is
/// a template image, so macOS tints it with the menu bar's own foreground
/// colour like every other extra rather than drawing it in a colour of its
/// own. They are built from `Resources/Mark/MentorMark.svg` by
/// `scripts/mark-assets.swift` (`make mark`).
@MainActor
enum MenuBarMarkImage {
    private static var loaded: [MenuBarMark: NSImage] = [:]

    static func image(for mark: MenuBarMark) -> NSImage? {
        if let found = loaded[mark] { return found }
        guard let url = Bundle.main.url(forResource: "MenuBarMark-\(mark.rawValue)", withExtension: "pdf"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = nil
        loaded[mark] = image
        return image
    }
}
