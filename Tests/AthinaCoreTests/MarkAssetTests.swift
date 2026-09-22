import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import AthinaCore

/// The committed assets against the mark they are built from.
///
/// The app icon is generated from `Resources/Mark/AthinaMark.svg` and the menu
/// bar mark from `Resources/Mark/AthinaOwl.svg`, both by
/// `scripts/mark-assets.swift` and both committed, so a plain build needs
/// nothing but the repository. That makes them the one thing in the build that
/// can silently fall out of step with the code: a variant added to
/// `MenuBarMark` with no file behind it would show the menu bar nothing, and a
/// variant drawn at a different size would shift every other menu bar extra
/// sideways whenever Athina's state changed.
@Suite struct MarkAssetTests {
    /// The repository, found from this file rather than from the working
    /// directory, so the suite passes wherever `swift test` is run from.
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AthinaCoreTests
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

    /// The rule the menu bar depends on: one width in every mode, so Athina
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

    /// The check that catches the one mistake that matters: a master or the
    /// script that draws it was edited and `make mark` was not run, so the icon
    /// and the mark in the bundle are of an older drawing.
    ///
    /// It compares what the assets were built from rather than rebuilding
    /// them, because Core Graphics stamps the running macOS version into every
    /// PDF it writes, so two machines cannot produce the same bytes.
    @Test func theAssetsWereBuiltFromTheSourcesThatAreHereNow() throws {
        let record = try String(contentsOf: markDirectory.appendingPathComponent("built-from.txt"), encoding: .utf8)
        // The Athena drawing behind the app icon, the owl behind the menu bar,
        // and the script that carries the rest of the drawing: the inset, the
        // eye treatments, the z's and the per-size thickening are constants
        // there, not in either master.
        let sources = [
            markDirectory.appendingPathComponent("AthinaMark.svg"),
            markDirectory.appendingPathComponent("AthinaOwl.svg"),
            root.appendingPathComponent("scripts/mark-assets.swift"),
        ]
        for url in sources {
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(record.contains("\(url.lastPathComponent) \(digest)"),
                    "\(url.lastPathComponent) has changed since the assets were built; run `make mark`")
        }
        // And the set it was built for is the set the code can ask for.
        let variants = record.split(separator: "\n")
            .first { $0.hasPrefix("variants ") }?
            .dropFirst("variants ".count)
            .split(separator: " ")
            .map(String.init) ?? []
        #expect(Set(variants) == Set(MenuBarMark.allCases.map(\.rawValue)),
                "the variant set has changed since the assets were built; run `make mark`")
    }

    /// The cream layer and the drawing are two independent groups, which is
    /// what lets the icon take the whole artwork while the thickening that
    /// keeps it legible at 16 and 32 px touches the line art alone.
    @Test func theIconMasterCarriesBothGroupsSoEitherCanBeUsedAlone() throws {
        let drawing = try MasterDrawing(contentsOf: markDirectory.appendingPathComponent("AthinaMark.svg"))
        #expect(drawing.groups == ["shapes", "lineart"])
        // The cream layer is carried as primitives, not as a traced outline,
        // so its edges stay exact at every size the icon is drawn at.
        #expect(Set(drawing.layer("shapes").map(\.kind)) == ["circle", "rect", "polygon"])
        let lineart = drawing.layer("lineart")
        #expect(!lineart.isEmpty)
        #expect(lineart.allSatisfy { $0.kind == "path" })
        // Nothing is drawn outside the two groups, so taking either one really
        // does take the whole of that layer.
        #expect(drawing.shapes.allSatisfy { $0.group != nil })
    }

    /// The owl's states are made out of its own parts, so the menu bar asset
    /// depends on the drawing still being four closed subpaths: the body, the
    /// cutout holding both eyes, and a pupil in each. A re-export that merged
    /// or split them would change what the states mean.
    ///
    /// Counted the way the generator counts them, over every path element in
    /// the drawing rather than over whichever one comes first, so a re-export
    /// that split the owl across several paths is measured whole.
    @Test func theOwlMasterStillHasTheFourPartsTheStatesAreMadeFrom() throws {
        let drawing = try MasterDrawing(contentsOf: markDirectory.appendingPathComponent("AthinaOwl.svg"))
        #expect(drawing.shapes.allSatisfy { $0.kind == "path" }, "the owl is path data alone")
        let commands = drawing.shapes.flatMap(\.commandLetters)
        let starts = commands.filter { $0 == "M" || $0 == "m" }.count
        let closes = commands.filter { $0 == "Z" || $0 == "z" }.count
        #expect(starts == 4, "the owl should be four subpaths, found \(starts)")
        #expect(closes == starts, "every subpath should be closed; \(starts) start, \(closes) close")
        // Content credentials belong with the artwork, not in a built asset.
        #expect(!drawing.elementNames.contains("metadata"))
        #expect(drawing.elementNames.allSatisfy { !$0.localizedCaseInsensitiveContains("c2pa") })
        #expect(drawing.attributeNames.allSatisfy { !$0.localizedCaseInsensitiveContains("c2pa") })
    }

    /// The pictures at the top of the README are drawn by the same script from
    /// the same masters, so they are held to the same record: every one it
    /// names is committed, the README shows exactly those, and nothing else
    /// drawn for the README is left lying beside them.
    @Test func theReadmeShowsThePicturesTheScriptDrew() throws {
        let record = try String(contentsOf: markDirectory.appendingPathComponent("built-from.txt"), encoding: .utf8)
        let drawn = Set(record.split(separator: "\n")
            .first { $0.hasPrefix("readme ") }?
            .dropFirst("readme ".count)
            .split(separator: " ")
            .map(String.init) ?? [])
        #expect(drawn.contains("ReadmeIcon.png"), "the record names no README icon; run `make mark`")
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: markDirectory.path)
            .filter { $0.hasPrefix("Readme") })
        #expect(files == drawn, "the README pictures on disk are not the ones last drawn; run `make mark`")

        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let shown = Set(readme.matches(of: /Resources\/Mark\/(Readme[A-Za-z-]+\.[a-z]+)/).map { String($0.output.1) })
        #expect(shown == drawn, "the README shows \(shown.sorted()), but the script drew \(drawn.sorted())")
    }

    /// The README icon is the icon as Finder draws it, masked and shadowed,
    /// not the full bleed square the .icns carries: its corners are clear, so
    /// the page shows through them the way the desktop does in the Dock.
    @Test func theReadmeIconIsMaskedTheWayFinderShowsIt() throws {
        let url = markDirectory.appendingPathComponent("ReadmeIcon.png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("cannot read ReadmeIcon.png; run `make mark`")
            return
        }
        #expect(image.width == 1024 && image.height == 1024, "ReadmeIcon.png is \(image.width) x \(image.height)")
        let alpha = try alphaSamples(of: image, at: [(0, 0), (1023, 0), (0, 1023), (1023, 1023), (112, 112), (512, 512)])
        #expect(alpha[0...4].allSatisfy { $0 == 0 }, "the corners should be clear, found \(alpha)")
        #expect(alpha[5] == 255, "the body should be opaque, found \(alpha[5])")
    }

    /// The owl beside the README's line about it is one file per GitHub theme,
    /// each in that theme's text colour, so it reads as part of the line in
    /// both, the way the menu bar tints its template.
    @Test func theReadmeOwlHasOneInkPerTheme() throws {
        for (theme, ink) in [("light", "#1f2328"), ("dark", "#f0f6fc")] {
            let url = markDirectory.appendingPathComponent("ReadmeOwl-\(theme).svg")
            let document = try XMLDocument(contentsOf: url)
            let fills = try document.nodes(forXPath: "//*[local-name()='path']/@fill").compactMap(\.stringValue)
            #expect(fills == [ink], "ReadmeOwl-\(theme).svg is filled \(fills), not \(ink)")
        }
    }

    private func alphaSamples(of image: CGImage, at points: [(Int, Int)]) throws -> [UInt8] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drawn)
        // The bitmap's rows run top down in memory, as the points are given.
        return points.map { pixels[($0.1 * width + $0.0) * 4 + 3] }
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

/// A master read the way `scripts/mark-assets.swift` reads it: the drawable
/// elements in document order, each with the group it belongs to and, for a
/// path, the command letters its data is made of.
///
/// It is a real XML parse rather than a search through the text, so a comment
/// cannot be mistaken for geometry and every element is seen, not just the
/// first one that matches.
private struct MasterDrawing {
    struct Shape {
        var group: String?
        var kind: String
        /// The SVG path commands, in order. Empty for a primitive, which has
        /// no path data of its own.
        var commandLetters: [Character]
    }

    private static let drawable: Set<String> = ["path", "circle", "rect", "polygon", "ellipse", "line", "polyline"]

    var shapes: [Shape] = []
    /// Every element and attribute name in the file, so what the drawing does
    /// not carry can be asserted as well as what it does.
    var elementNames: [String] = []
    var attributeNames: [String] = []

    var groups: Set<String> { Set(shapes.compactMap(\.group)) }

    /// The drawable elements of one named group.
    func layer(_ id: String) -> [Shape] { shapes.filter { $0.group == id } }

    init(contentsOf url: URL) throws {
        let document = try XMLDocument(contentsOf: url)
        guard let root = document.rootElement() else { return }
        walk(root, group: nil)
    }

    private mutating func walk(_ element: XMLElement, group: String?) {
        let name = element.name ?? ""
        elementNames.append(name)
        attributeNames.append(contentsOf: (element.attributes ?? []).compactMap(\.name))
        let group = name == "g" ? (element.attribute(forName: "id")?.stringValue ?? group) : group
        if Self.drawable.contains(name) {
            let data = name == "path" ? element.attribute(forName: "d")?.stringValue ?? "" : ""
            shapes.append(Shape(group: group, kind: name, commandLetters: Array(data.filter(\.isLetter))))
        }
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            walk(child, group: group)
        }
    }
}
