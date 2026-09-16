import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MentorCore

/// The committed assets against the mark they are built from.
///
/// The app icon and the menu bar mark are generated from
/// `Resources/Mark/MentorMark.svg` by `scripts/mark-assets.swift` and
/// committed, so a plain build needs nothing but the repository. That makes
/// them the one thing in the build that can silently fall out of step with the
/// code: a variant added to `MenuBarMark` with no file behind it would show
/// the menu bar nothing, and a variant drawn at a different size would shift
/// every other menu bar extra sideways whenever Mentor's state changed.
@Suite struct MarkAssetTests {
    /// The repository, found from this file rather than from the working
    /// directory, so the suite passes wherever `swift test` is run from.
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MentorCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the repository
    }

    private var markDirectory: URL { root.appendingPathComponent("Resources/Mark") }

    private func pageSize(of url: URL) -> CGSize? {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        return CGSize(width: box.width, height: box.height)
    }

    @Test func everyVariantOfTheMarkHasAFile() {
        for mark in MenuBarMark.allCases {
            let url = markDirectory.appendingPathComponent("MenuBarMark-\(mark.rawValue).pdf")
            #expect(FileManager.default.fileExists(atPath: url.path),
                    "no menu bar file for \(mark.rawValue); run `make mark`")
        }
    }

    /// The rule the menu bar depends on: one width in every mode, so Mentor
    /// changing state never moves the other extras.
    @Test func everyVariantOfTheMarkIsTheSameSize() {
        var sizes: [MenuBarMark: CGSize] = [:]
        for mark in MenuBarMark.allCases {
            let url = markDirectory.appendingPathComponent("MenuBarMark-\(mark.rawValue).pdf")
            guard let size = pageSize(of: url) else {
                Issue.record("cannot read \(url.lastPathComponent)")
                continue
            }
            sizes[mark] = size
        }
        #expect(sizes.count == MenuBarMark.allCases.count)
        guard let first = sizes[.watching] else { return }
        for (mark, size) in sizes {
            #expect(size == first, "\(mark.rawValue) is \(size), but watching is \(first)")
        }
        // The size the menu bar gives a symbol.
        #expect(first.height == 16)
    }

    /// No file left behind for a variant that no longer exists, so the set the
    /// menu bar can show is exactly the set in the code.
    @Test func noFileIsLeftForAVariantThatNoLongerExists() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: markDirectory.path)
            .filter { $0.hasPrefix("MenuBarMark-") }
        let expected = Set(MenuBarMark.allCases.map { "MenuBarMark-\($0.rawValue).pdf" })
        #expect(Set(files) == expected, "run `make mark` after changing the set")
    }

    /// The check that catches the one mistake that matters: the master was
    /// edited and `make mark` was not run, so the icon and the mark in the
    /// bundle are of an older drawing.
    ///
    /// It compares what the assets were built from rather than rebuilding
    /// them, because Core Graphics stamps the running macOS version into every
    /// PDF it writes, so two machines cannot produce the same bytes.
    @Test func theAssetsWereBuiltFromTheMasterThatIsHereNow() throws {
        let record = try String(contentsOf: markDirectory.appendingPathComponent("built-from.txt"), encoding: .utf8)
        let svg = try Data(contentsOf: markDirectory.appendingPathComponent("MentorMark.svg"))
        let digest = SHA256.hash(data: svg).map { String(format: "%02x", $0) }.joined()
        #expect(record.contains("MentorMark.svg \(digest)"),
                "Resources/Mark/MentorMark.svg has changed since the assets were built; run `make mark`")
        // And the set it was built for is the set the code can ask for.
        let variants = record.split(separator: "\n")
            .first { $0.hasPrefix("variants ") }?
            .dropFirst("variants ".count)
            .split(separator: " ")
            .map(String.init) ?? []
        #expect(Set(variants) == Set(MenuBarMark.allCases.map(\.rawValue)),
                "the variant set has changed since the assets were built; run `make mark`")
    }

    @Test func theMasterCarriesBothGroupsSoEitherCanBeUsedAlone() throws {
        let svg = try String(contentsOf: markDirectory.appendingPathComponent("MentorMark.svg"), encoding: .utf8)
        #expect(svg.contains("id=\"shapes\""))
        #expect(svg.contains("id=\"lineart\""))
        // The cream layer is carried as primitives, not as a traced outline.
        #expect(svg.contains("<circle"))
        #expect(svg.contains("<rect"))
        #expect(svg.contains("<polygon"))
    }

    /// The icon carries every size the format holds, so macOS never has to
    /// resample one from another and show a soft icon.
    @Test func theAppIconCarriesEverySize() {
        let url = root.appendingPathComponent("Resources/AppIcon.icns")
        #expect(FileManager.default.fileExists(atPath: url.path), "no app icon; run `make mark`")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            Issue.record("cannot read AppIcon.icns")
            return
        }
        var widths: Set<Int> = []
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int else { continue }
            widths.insert(width)
        }
        #expect(widths.isSuperset(of: [16, 32, 64, 128, 256, 512, 1024]), "sizes present: \(widths.sorted())")
    }
}
