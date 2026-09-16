import AppKit
import Testing
@testable import MentorCore

@Suite struct MenuBarIconTests {
    static let pointSizes: [CGFloat] = [13, 14, 16]

    @Test func everyModeKeepsItsSymbol() {
        let expected: [SensingMode: String] = [
            .watching: "eye.fill", .screenOnly: "eye.fill", .accessibilityOnly: "eye.fill",
            .idle: "eye", .paused: "eye.slash", .stopped: "eye.slash",
            .excluded: "hand.raised.fill", .waitingForPermissions: "eye.trianglebadge.exclamationmark",
        ]
        for mode in SensingMode.allCases {
            #expect(MenuBarIcon.symbolName(for: mode) == expected[mode], "\(mode)")
        }
    }

    @Test(arguments: MenuBarIconTests.pointSizes)
    func everyModeHasTheSameWidth(pointSize: CGFloat) {
        let widths = Set(SensingMode.allCases.map { MenuBarIcon.image(for: $0, pointSize: pointSize).size.width })
        #expect(widths.count == 1)
        let widest = MenuBarIcon.symbols.map { Self.symbol($0, pointSize).size.width }.max()
        #expect(widths.first == widest)
        // The symbols really do differ, so a bare symbol would move the item.
        #expect(Self.symbol("hand.raised.fill", pointSize).size.width < Self.symbol("eye.fill", pointSize).size.width)
    }

    /// At the menu bar's own size, what the app draws, the eyes are 21 pt,
    /// the raised hand 16 pt, and the warning badge 23 pt on macOS 27.
    @Test func everyModeHasTheSameWidthAtTheMenuBarSize() {
        let widths = Set(SensingMode.allCases.map { MenuBarIcon.image(for: $0).size.width })
        #expect(widths == [MenuBarIcon.width()])
    }

    /// The system centres a status item's image vertically by its height, so
    /// each icon keeps its symbol's height and the symbol sits where it did.
    @Test(arguments: MenuBarIconTests.pointSizes)
    func keepsEachSymbolsHeightAndTemplateRendering(pointSize: CGFloat) {
        for mode in SensingMode.allCases {
            let icon = MenuBarIcon.image(for: mode, pointSize: pointSize)
            #expect(icon.isTemplate, "\(mode)")
            #expect(icon.size.height == Self.symbol(MenuBarIcon.symbolName(for: mode), pointSize).size.height, "\(mode)")
        }
    }

    /// The icon draws the same ink as the bare symbol, moved right by whole
    /// points to centre it, and nothing else.
    @Test(arguments: MenuBarIconTests.pointSizes)
    func drawsTheSymbolCentredOnWholePoints(pointSize: CGFloat) throws {
        for mode in SensingMode.allCases {
            let symbol = Self.symbol(MenuBarIcon.symbolName(for: mode), pointSize)
            let icon = MenuBarIcon.image(for: mode, pointSize: pointSize)
            let offset = (icon.size.width - symbol.size.width) / 2
            let symbolInk = try #require(Self.ink(of: symbol, canvasWidth: icon.size.width))
            let iconInk = try #require(Self.ink(of: icon, canvasWidth: icon.size.width))
            #expect(iconInk.minY == symbolInk.minY && iconInk.maxY == symbolInk.maxY, "\(mode)")
            let shift = iconInk.minX - symbolInk.minX
            #expect(shift == offset.rounded(.down), "\(mode)")
            #expect(iconInk.width == symbolInk.width, "\(mode)")
        }
    }

    private static func symbol(_ name: String, _ pointSize: CGFloat) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))!
    }

    /// The inked rectangle, in points, of an image drawn at the left of a
    /// canvas `canvasWidth` wide, measured at 2x.
    private static func ink(of image: NSImage, canvasWidth: CGFloat) -> CGRect? {
        let scale: CGFloat = 2
        let pixelsWide = Int(canvasWidth * scale), pixelsHigh = Int(image.size.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = CGSize(width: canvasWidth, height: image.size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        var minX = pixelsWide, maxX = -1, minY = pixelsHigh, maxY = -1
        for y in 0..<pixelsHigh {
            for x in 0..<pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale, width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}
