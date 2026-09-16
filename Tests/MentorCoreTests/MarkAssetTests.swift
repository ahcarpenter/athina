import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MentorCore

/// The committed assets against the mark they are built from.
///
/// The app icon is generated from `Resources/Mark/MentorMark.svg` and the menu
/// bar mark from `Resources/Mark/MentorOwl.svg`, both by
/// `scripts/mark-assets.swift` and both committed, so a plain build needs
/// nothing but the repository. That makes them the one thing in the build that
/// can silently fall out of step with the code: a variant added to
/// `MenuBarMark` with no file behind it would show the menu bar nothing, and a
/// variant drawn at a different size would shift every other menu bar extra
/// sideways whenever Mentor's state changed.
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
            markDirectory.appendingPathComponent("MentorMark.svg"),
            markDirectory.appendingPathComponent("MentorOwl.svg"),
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
        let drawing = try MasterDrawing(contentsOf: markDirectory.appendingPathComponent("MentorMark.svg"))
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
        let drawing = try MasterDrawing(contentsOf: markDirectory.appendingPathComponent("MentorOwl.svg"))
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
