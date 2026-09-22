import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import AthinaCore

/// Vision runs on-device without any permission, so OCR and the coordinate
/// mapping can be verified against a drawn frame.
@Suite struct TextRecognizerTests {
    /// Draws into an exact 800 x 500 pixel bitmap so coordinates are not scaled by a Retina context.
    private func drawnFrame(background: NSColor = .white, foreground: NSColor = .black) -> CapturedFrame? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 500, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        background.setFill()
        CGRect(x: 0, y: 0, width: 800, height: 500).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 36, weight: .medium),
            .foregroundColor: foreground,
        ]
        // Bottom-left origin: this line sits near the top of the frame.
        NSAttributedString(string: "Athina foundation", attributes: attributes).draw(at: CGPoint(x: 60, y: 380))
        NSAttributedString(string: "Journal retention", attributes: attributes).draw(at: CGPoint(x: 60, y: 120))
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = rep.cgImage else { return nil }
        // Pretend the frame shows a 1600 x 1000 point display at (100, 50): two points per pixel.
        return CapturedFrame(image: cgImage, displayID: 1, screenRect: CGRect(x: 100, y: 50, width: 1600, height: 1000))
    }

    @Test func recognizesTextAndMapsBoxesToScreenPoints() async throws {
        let frame = try #require(drawnFrame())
        #expect(frame.image.width == 800 && frame.image.height == 500)
        let blocks = try await TextRecognizer().recognize(frame, level: .fast)
        let texts = blocks.map(\.text)
        #expect(texts.contains { $0.localizedCaseInsensitiveContains("Athina foundation") })
        #expect(texts.contains { $0.localizedCaseInsensitiveContains("Journal retention") })

        let top = try #require(blocks.first { $0.text.localizedCaseInsensitiveContains("Athina") })
        let bottom = try #require(blocks.first { $0.text.localizedCaseInsensitiveContains("Journal") })
        // Image coordinates have their origin at the top-left of the frame.
        #expect(top.imageRect.minY < bottom.imageRect.minY)
        #expect(top.imageRect.minX > 40 && top.imageRect.minX < 80)
        #expect(top.imageRect.minY > 60 && top.imageRect.minY < 100)
        // Screen rects are scaled by points-per-pixel (2) and offset by the display origin.
        #expect(abs(top.screenRect.minX - (100 + top.imageRect.minX * 2)) < 0.01)
        #expect(abs(top.screenRect.minY - (50 + top.imageRect.minY * 2)) < 0.01)
        #expect(abs(top.screenRect.width - top.imageRect.width * 2) < 0.01)
        #expect(blocks.allSatisfy { $0.confidence > 0 })
    }

    /// Terminals and dark-mode editors show light text on a dark background. The default
    /// recognition level must read them; the fast level returns nothing for such frames.
    @Test func accurateLevelReadsLightTextOnDarkBackground() async throws {
        let frame = try #require(drawnFrame(
            background: NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.16, alpha: 1),
            foreground: NSColor(calibratedWhite: 0.9, alpha: 1)
        ))
        let blocks = try await TextRecognizer().recognize(frame, level: SensingSettings().ocrLevel)
        let texts = blocks.map(\.text)
        #expect(texts.contains { $0.localizedCaseInsensitiveContains("Athina foundation") })
        #expect(texts.contains { $0.localizedCaseInsensitiveContains("Journal retention") })
    }
}
