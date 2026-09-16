import AppKit

/// The menu bar item's icon: one template SF Symbol per sensing mode, drawn
/// centred in an image as wide as the widest of them. The symbols differ in
/// width (the raised hand is 5 pt narrower than the eyes at the menu bar's
/// size, the warning badge 2 pt wider), and the system sizes a status item to
/// its icon, so a bare symbol would move every menu bar extra to Mentor's left
/// each time an excluded app came forward. `MenuBarExtra` flattens its label
/// to an image and a title, so a SwiftUI frame around the symbol does not
/// survive; the width has to be in the image itself.
public enum MenuBarIcon {
    /// Every symbol the icon can show, so the width covers all of them.
    static let symbols = Set(SensingMode.allCases.map(symbolName(for:)))

    public static func symbolName(for mode: SensingMode) -> String {
        switch mode {
        case .watching, .screenOnly, .accessibilityOnly: "eye.fill"
        case .idle: "eye"
        case .paused, .stopped: "eye.slash"
        case .excluded: "hand.raised.fill"
        case .waitingForPermissions: "eye.trianglebadge.exclamationmark"
        }
    }

    /// The size the menu bar draws a symbol label at: its own font's size,
    /// which is what a bare `Image(systemName:)` label is drawn at.
    public static var menuBarPointSize: CGFloat {
        NSFont.menuBarFont(ofSize: 0).pointSize
    }

    /// The mode's symbol as a template image at `pointSize`, as wide as the
    /// widest mode symbol and as tall as its own symbol, so the status item
    /// keeps one width while the system still centres each symbol vertically
    /// exactly as it would a bare one. The offset is whole points, so the
    /// symbol lands on pixel boundaries at any backing scale.
    public static func image(for mode: SensingMode, pointSize: CGFloat = menuBarPointSize) -> NSImage {
        let symbol = symbolImage(symbolName(for: mode), pointSize: pointSize)
        let size = CGSize(width: width(pointSize: pointSize), height: symbol.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            let x = ((size.width - symbol.size.width) / 2).rounded(.down)
            symbol.draw(in: CGRect(origin: CGPoint(x: x, y: 0), size: symbol.size))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The icon's width at `pointSize`: the widest mode symbol's.
    public static func width(pointSize: CGFloat = menuBarPointSize) -> CGFloat {
        symbols.map { symbolImage($0, pointSize: pointSize).size.width }.max() ?? 0
    }

    private static func symbolImage(_ name: String, pointSize: CGFloat) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            preconditionFailure("SF Symbol \(name) is missing")
        }
        return image
    }
}
