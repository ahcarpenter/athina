#!/usr/bin/env swift
import AppKit
import CoreGraphics
import CryptoKit
import Foundation

// Builds every asset the app draws its mark from, out of the two committed
// masters: Resources/Mark/AthinaMark.svg, the Athena drawing, for the app
// icon, and Resources/Mark/AthinaOwl.svg, the owl, for the menu bar. Run it
// with `make mark` whenever either changes; its outputs are committed so a
// plain `make build` needs nothing but the repository.
//
// It produces:
//
//   Resources/AppIcon.icns           the app icon, full Athena artwork, every size
//   Resources/Mark/MenuBarMark-*.pdf the menu bar mark, the owl's silhouette,
//                                    one file per variant of MenuBarMark
//   Resources/Mark/ReadmeIcon.png    the app icon as Finder draws it, for the
//                                    top of README.md
//   Resources/Mark/ReadmeOwl-*.svg   the owl, watching, in GitHub's light and
//                                    dark text colours, for README.md
//
// Two things about macOS 26 shape what it does. First, the system masks a
// legacy .icns to the standard app icon shape itself and adds the shadow: a
// full bleed square here is scaled into the 824 of 1024 body and rounded off,
// in Finder, in the Dock and in About. So nothing here draws a rounded
// rectangle or a shadow of its own. Second, a menu bar extra's image is
// tinted by the system when it is a template, so the menu bar files carry
// shape and alpha only, never colour.

enum Failure: Error { case iconutil, pdfLengthChanged, owlShape(String), svg(String), readmeIcon(String) }

/// A small reader for the subset of SVG this project's mark uses: groups,
/// paths, and the three primitives the cream layer is made of, all in one flat
/// coordinate space. Enough to rasterise the committed master source, and no
/// more.
///
/// Anything outside that subset stops the build. Both assets are generated and
/// committed, so a master carrying something this reader does not understand
/// would otherwise be drawn wrong and committed wrong with nothing to show for
/// it.
enum SVG {
    struct Element {
        var path: CGPath
        var fill: CGColor?
        var evenOdd: Bool
        var group: String?
    }

    struct Document {
        var elements: [Element]
    }

    static func parse(contentsOf url: URL) throws -> Document {
        guard let root = try XMLDocument(contentsOf: url).rootElement() else { return Document(elements: []) }
        var elements: [Element] = []
        try read(root, into: &elements, fill: CGColor(red: 0, green: 0, blue: 0, alpha: 1), group: nil)
        return Document(elements: elements)
    }

    // MARK: Reading

    /// Walks the tree, carrying down what an element inherits from the groups
    /// it sits in: the fill, and the name of the group itself.
    ///
    /// Only `svg` and `g` hold other elements. Anything else is drawn or
    /// refused, never descended into: `defs`, `clipPath` and `mask` carry
    /// geometry that is referred to rather than painted, and painting it fills
    /// the icon with a shape that was never meant to be seen.
    ///
    /// A `transform` is refused too. The masters are written in one flat
    /// coordinate space, so nothing here needs one, and an implementation
    /// nothing exercises is one that quietly draws the wrong geometry the day
    /// a re-export does carry it.
    private static func read(
        _ element: XMLElement, into elements: inout [Element],
        fill inheritedFill: CGColor?, group: String?
    ) throws {
        let name = element.name ?? ""
        if attribute("transform", of: element) != nil {
            throw Failure.svg("<\(name)> carries a transform, which this reader does not apply; the "
                              + "masters are written in one flat coordinate space and need none")
        }
        let fill = attribute("fill", of: element).map(colour) ?? inheritedFill
        guard name == "svg" || name == "g" else {
            elements.append(Element(path: try shape(of: element), fill: fill,
                                    evenOdd: attribute("fill-rule", of: element) == "evenodd", group: group))
            return
        }
        let group = name == "g" ? attribute("id", of: element) ?? group : group
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            try read(child, into: &elements, fill: fill, group: group)
        }
    }

    /// One drawable element's geometry in its own coordinates: a path, or one
    /// of the three primitives the cream layer is made of.
    private static func shape(of element: XMLElement) throws -> CGPath {
        let kind = element.name ?? "?"
        func number(_ name: String) -> Double { attribute(name, of: element).flatMap(Double.init) ?? 0 }
        func required(_ name: String) throws -> String {
            guard let value = attribute(name, of: element) else {
                throw Failure.svg("<\(kind)> carries no \(name) for this reader to draw")
            }
            return value
        }
        switch kind {
        case "path":
            return try pathData(required("d"))
        case "circle":
            let cx = number("cx"), cy = number("cy"), r = number("r")
            let p = CGMutablePath()
            p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            return p
        case "rect":
            let p = CGMutablePath()
            p.addRect(CGRect(x: number("x"), y: number("y"),
                             width: number("width"), height: number("height")))
            return p
        case "polygon":
            let n = numbers(try required("points"))
            let p = CGMutablePath()
            for i in stride(from: 0, to: n.count - 1, by: 2) {
                let pt = CGPoint(x: n[i], y: n[i + 1])
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
            return p
        default:
            throw Failure.svg("<\(kind)> is not an element this reader draws; the masters carry "
                              + "groups, paths, circles, rects and polygons and nothing else")
        }
    }

    private static func attribute(_ name: String, of element: XMLElement) -> String? {
        element.attribute(forName: name)?.stringValue
    }

    private static func numbers(_ text: String) -> [Double] {
        var found: [Double] = []
        var current = ""
        func flush() { if let v = Double(current) { found.append(v) }; current = "" }
        for character in text {
            if character.isNumber || character == "." { current.append(character) }
            else if character == "-" || character == "+" {
                // A sign starts a new number unless it follows an exponent.
                if current.hasSuffix("e") || current.hasSuffix("E") { current.append(character) }
                else { flush(); current.append(character) }
            } else if character == "e" || character == "E" { current.append(character) }
            else { flush() }
        }
        flush()
        return found
    }

    private static func colour(_ text: String) -> CGColor? {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value == "none" { return nil }
        guard value.hasPrefix("#") else { return CGColor(red: 0, green: 0, blue: 0, alpha: 1) }
        value.removeFirst()
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard let n = UInt32(value, radix: 16) else { return nil }
        return CGColor(red: CGFloat((n >> 16) & 0xFF) / 255, green: CGFloat((n >> 8) & 0xFF) / 255,
                       blue: CGFloat(n & 0xFF) / 255, alpha: 1)
    }

    private static func pathData(_ d: String) throws -> CGMutablePath {
        let path = CGMutablePath()
        var tokens: [String] = []
        var current = ""
        for character in d {
            if character.isLetter {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(character))
            } else if character == "-" || character == "+" {
                if current.hasSuffix("e") || current.hasSuffix("E") { current.append(character) }
                else { if !current.isEmpty { tokens.append(current) }; current = String(character) }
            } else if character.isNumber || character == "." || character == "e" || character == "E" {
                current.append(character)
            } else {
                if !current.isEmpty { tokens.append(current); current = "" }
            }
        }
        if !current.isEmpty { tokens.append(current) }

        var point = CGPoint.zero
        var start = CGPoint.zero
        var command = "M"
        var i = 0
        func next() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
        while i < tokens.count {
            if tokens[i].count == 1, let c = tokens[i].first, c.isLetter { command = tokens[i]; i += 1 }
            guard i < tokens.count || command.lowercased() == "z" else { break }
            switch command {
            case "M", "m":
                var p = CGPoint(x: next(), y: next())
                if command == "m" { p.x += point.x; p.y += point.y }
                path.move(to: p); point = p; start = p
                command = command == "M" ? "L" : "l"
            case "L", "l":
                var p = CGPoint(x: next(), y: next())
                if command == "l" { p.x += point.x; p.y += point.y }
                path.addLine(to: p); point = p
            case "H", "h":
                var x = next(); if command == "h" { x += point.x }
                let p = CGPoint(x: x, y: point.y); path.addLine(to: p); point = p
            case "V", "v":
                var y = next(); if command == "v" { y += point.y }
                let p = CGPoint(x: point.x, y: y); path.addLine(to: p); point = p
            case "C", "c":
                var c1 = CGPoint(x: next(), y: next())
                var c2 = CGPoint(x: next(), y: next())
                var p = CGPoint(x: next(), y: next())
                if command == "c" {
                    c1.x += point.x; c1.y += point.y; c2.x += point.x; c2.y += point.y
                    p.x += point.x; p.y += point.y
                }
                path.addCurve(to: p, control1: c1, control2: c2); point = p
            case "Z", "z":
                path.closeSubpath(); point = start
                // Nothing follows a close but the next command.
                if i < tokens.count, let c = tokens[i].first, !c.isLetter { i += 1 }
            default:
                throw Failure.svg("path command '\(command)' is not one this reader draws; the "
                                  + "masters are written with M, L, H, V, C and Z alone")
            }
        }
        return path
    }
}

// MARK: Where things are

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", isDirectory: true)
let master = root.appendingPathComponent("Resources/Mark/AthinaMark.svg")
let markDirectory = root.appendingPathComponent("Resources/Mark", isDirectory: true)
let document = try SVG.parse(contentsOf: master)

let ink = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

/// The drawing's own extent, which is what gets centred: the master's page has
/// uneven margins around it.
let content: CGRect = document.elements.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }

// MARK: The app icon

/// Full bleed, because macOS does the masking. The drawing is kept clear of
/// the corners, which the mask rounds away.
let iconBackground = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let iconHeightFraction = 0.86

/// How much bigger and heavier the drawing is drawn at each icon size.
///
/// A 22 unit stroke in a 1143 tall drawing is under a pixel by the time the
/// icon is 32 px, so without this the line art greys out instead of reading as
/// lines. Drawing each size to suit itself is what the .icns format exists to
/// allow; it is optical sizing, not a different drawing.
func iconTuning(for size: Int) -> (fraction: Double, thicken: Double) {
    switch size {
    case ...16: (0.98, 15)
    case 17...32: (0.94, 11)
    case 33...64: (0.90, 5)
    case 65...128: (0.88, 2)
    default: (iconHeightFraction, 0)
    }
}

func drawIcon(size: Int) -> CGImage {
    let tuned = iconTuning(for: size)
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(iconBackground)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.setAllowsAntialiasing(true)

    let canvas = Double(size)
    let scale = canvas * tuned.fraction / content.height
    let drawnWidth = content.width * scale, drawnHeight = content.height * scale
    context.translateBy(x: CGFloat((canvas - drawnWidth) / 2), y: CGFloat((canvas - drawnHeight) / 2))
    context.translateBy(x: 0, y: CGFloat(drawnHeight))
    context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
    context.translateBy(x: -content.minX, y: -content.minY)
    for element in document.elements {
        guard let fill = element.fill else { continue }
        context.addPath(element.path)
        context.setFillColor(fill)
        context.fillPath(using: element.evenOdd ? .evenOdd : .winding)
        // Stroking the same outline widens it evenly on both sides, so the
        // line keeps its shape and only gains weight.
        if tuned.thicken > 0, element.group == "lineart" {
            context.addPath(element.path)
            context.setStrokeColor(fill)
            context.setLineWidth(CGFloat(tuned.thicken))
            context.setLineJoin(.round)
            context.strokePath()
        }
    }
    return context.makeImage()!
}

func writeIcon() throws {
    let iconset = markDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    // Every size the .icns format carries, each drawn from the vector rather
    // than resampled from a larger bitmap, so none of them is soft.
    let sizes: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
        ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (name, pixels) in sizes {
        let rep = NSBitmapImageRep(cgImage: drawIcon(size: pixels))
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("\(name).png"))
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["--convert", "icns", "--output",
                         root.appendingPathComponent("Resources/AppIcon.icns").path, iconset.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw Failure.iconutil }
    try FileManager.default.removeItem(at: iconset)
    print("  Resources/AppIcon.icns  (\(sizes.count) sizes, drawing at \(iconHeightFraction) of the canvas)")
}

// MARK: The menu bar mark

// The menu bar shows the owl, the captain's own artwork, not a reduction of
// the Athena drawing: it is a solid silhouette, so it sits among the menu
// bar's other extras instead of reading lighter than all of them the way a
// line drawing does at 16 points.
//
// Its states are made out of the drawing rather than hung off it. The owl's
// eyes are the boldest thing in it at this size and they are what watching
// means, so they carry the states: the silhouette never changes, and the item
// keeps ONE width in every mode.

let owlMaster = root.appendingPathComponent("Resources/Mark/AthinaOwl.svg")
let owl = try SVG.parse(contentsOf: owlMaster)

/// The owl is one path made of four closed subpaths. They are told apart by
/// what they are rather than by the order they happen to be written in, so a
/// re-export of the artwork does not silently swap them.
struct Owl {
    var body: CGPath
    var faceCutout: CGPath
    var pupils: [CGPath]
    /// The white of each eye, concentric with its pupil. Measured from the
    /// drawing: the cutout reaches 35.8 units from each pupil's centre before
    /// the body's ink begins again.
    var eyes: [CGPath]
    var bounds: CGRect

    static func read(_ document: SVG.Document) throws -> Owl {
        var subpaths: [CGPath] = []
        var current = CGMutablePath()
        for element in document.elements {
            element.path.applyWithBlock { pointer in
                let e = pointer.pointee
                switch e.type {
                case .moveToPoint:
                    if !current.isEmpty { subpaths.append(current.copy()!) }
                    current = CGMutablePath()
                    current.move(to: e.points[0])
                case .addLineToPoint: current.addLine(to: e.points[0])
                case .addCurveToPoint: current.addCurve(to: e.points[2], control1: e.points[0], control2: e.points[1])
                case .addQuadCurveToPoint: current.addQuadCurve(to: e.points[1], control: e.points[0])
                case .closeSubpath: current.closeSubpath()
                @unknown default: break
                }
            }
        }
        if !current.isEmpty { subpaths.append(current.copy()!) }
        guard subpaths.count == 4 else { throw Failure.owlShape("expected 4 subpaths, found \(subpaths.count)") }

        let byArea = subpaths.sorted {
            $0.boundingBoxOfPath.width * $0.boundingBoxOfPath.height
                > $1.boundingBoxOfPath.width * $1.boundingBoxOfPath.height
        }
        let body = byArea[0], faceCutout = byArea[1]
        // The pupils are the two small round ones, left first.
        let pupils = byArea[2...].sorted { $0.boundingBoxOfPath.midX < $1.boundingBoxOfPath.midX }
        for pupil in pupils {
            let box = pupil.boundingBoxOfPath
            guard abs(box.width - box.height) < 1, box.width < faceCutout.boundingBoxOfPath.width / 3 else {
                throw Failure.owlShape("a pupil is not the round shape it should be: \(box)")
            }
        }
        let eyeRadius = 35.8
        let eyes = pupils.map { pupil -> CGPath in
            let centre = pupil.boundingBoxOfPath
            return CGPath(ellipseIn: CGRect(x: centre.midX - eyeRadius, y: centre.midY - eyeRadius,
                                            width: eyeRadius * 2, height: eyeRadius * 2), transform: nil)
        }
        return Owl(body: body, faceCutout: faceCutout, pupils: pupils, eyes: eyes,
                   bounds: body.boundingBoxOfPath)
    }

    /// Everything but the eyes: the silhouette with the face cut out of it.
    /// Every state starts here, which is why none of them can change the
    /// outline or the width.
    var base: CGPath { body.subtracting(faceCutout) }
}

let parts = try Owl.read(owl)

/// What a state does to the owl's eyes. The drawing carries the state; nothing
/// is hung off the side of it.
enum Eyes: String {
    /// Both pupils where the artist put them.
    case open
    /// No pupils, so the eye cutouts read as closed. The captain's own words,
    /// said of the sleeping state when idle and paused wore each other's
    /// faces: "have it have no dots in it's eyes as if they're closed".
    case closed
    /// A lid down over the top of each eye, pupils still under it.
    case halfLidded
    /// Pupils pushed to one side: awake, looking away from what is in front.
    case asideRight
    /// Pupils grown to fill most of the eye: a wide stare.
    case wide
    /// One eye open and one closed.
    case winking
}

/// Two z's drifting off the owl, in the style of the reference the captain
/// sent: bold and geometric, square cut, the larger one nearest the owl and the
/// smaller one rising away from it.
///
/// They sit in the clear upper left of the owl's own bounding box, which is
/// empty in the drawing, so adding them does not widen the item. The width has
/// to be the same in every state or the menu bar's other extras move when
/// Athina's does.
func zed(height: Double, at origin: CGPoint) -> CGPath {
    // Proportions taken from the reference: a little taller than wide, one
    // weight for all three strokes, square cut ends, and counters left open
    // enough to survive a few pixels.
    let width = height * 0.80
    let t = height * 0.24

    // Built with y running up, which is how a Z reads when it is written out,
    // and then flipped into the drawing's own space, where y runs down the
    // page. Doing the flip here rather than by hand in the numbers is what
    // keeps the diagonal from coming out as an N.
    let top = origin.y + height - t
    let glyph = CGMutablePath()
    glyph.addRect(CGRect(x: origin.x, y: top, width: width, height: t))
    glyph.addRect(CGRect(x: origin.x, y: origin.y, width: width, height: t))
    let diagonal = CGMutablePath()
    diagonal.move(to: CGPoint(x: origin.x + width - t / 2, y: top))
    diagonal.addLine(to: CGPoint(x: origin.x + t / 2, y: origin.y + t))
    let band = diagonal.copy(strokingWithWidth: CGFloat(t), lineCap: .butt, lineJoin: .miter, miterLimit: 10)
    let upright = glyph.union(band)

    var flip = CGAffineTransform(translationX: 0, y: CGFloat(2 * origin.y + height))
        .scaledBy(x: 1, y: -1)
    return upright.copy(using: &flip) ?? upright
}

/// The pair, in the clear upper left of the owl's own bounding box: the larger
/// nearest the owl and the smaller drifting away from it, as in the reference.
var sleepMarks: CGPath {
    zed(height: 72, at: CGPoint(x: 70, y: 74))
        .union(zed(height: 50, at: CGPoint(x: 26, y: 20)))
}

func drawEyes(_ eyes: Eyes) -> CGPath {
    var path = parts.base
    func addPupil(_ index: Int, offsetBy dx: Double = 0, scaledBy factor: Double = 1) {
        let box = parts.pupils[index].boundingBoxOfPath
        let radius = box.width / 2 * factor
        let disc = CGPath(ellipseIn: CGRect(x: box.midX + dx - radius, y: box.midY - radius,
                                            width: radius * 2, height: radius * 2), transform: nil)
        path = path.union(disc)
    }
    switch eyes {
    case .open:
        addPupil(0); addPupil(1)
    case .closed:
        break
    case .halfLidded:
        // A drowsy eye closes from the top, and y runs down the page here, so
        // the lid falls from the eye's own minY to just past its centre. It is
        // cut to the eye's disc, so it can never spill past the cutout and
        // change the silhouette, and the pupils still show beneath it.
        for eye in parts.eyes {
            let box = eye.boundingBoxOfPath
            let lid = CGPath(rect: CGRect(x: box.minX - 1, y: box.minY,
                                          width: box.width + 2, height: box.height * 0.56), transform: nil)
            path = path.union(eye.intersection(lid))
        }
        addPupil(0); addPupil(1)
    case .asideRight:
        // Far enough to sit against the rim of the eye without touching it.
        let shift = 13.0
        addPupil(0, offsetBy: shift); addPupil(1, offsetBy: shift)
    case .wide:
        addPupil(0, scaledBy: 1.7); addPupil(1, scaledBy: 1.7)
    case .winking:
        addPupil(0)
        // The closed eye is filled in, so only one eye is still looking.
        path = path.union(parts.eyes[1])
    }
    return path
}

/// The item's box in points, the size the menu bar gives a symbol, and the
/// owl's width at that height from its own proportions.
///
/// The drawing is held off the top and bottom of that box by `menuBarInset`,
/// so the item sits inside its box the way the system's own extras do rather
/// than reading as the tallest thing in the bar. The box keeps its size
/// whatever the inset is, and every state is drawn at the same scale, so the
/// item is still one width in every mode.
let menuBarHeight = 16.0
let menuBarInset = 1.0
let menuBarWidth = (menuBarHeight * parts.bounds.width / parts.bounds.height * 2).rounded() / 2

/// Which treatment each state gets.
///
/// Changing this table is the whole of changing the set: the modes, their
/// names and the resolution that picks between them live in `MenuBarMark` and
/// do not move.
let set: [(mark: String, eyes: Eyes, asleep: Bool)] = [
    ("watching", .open, false),
    // Idle is the state that says the user has stepped away, so it is the
    // sleeping one: it takes the z's as well as the eyes.
    ("idle", .closed, true),
    ("paused", .halfLidded, false),
    ("excluded", .asideRight, false),
    ("needsSomething", .wide, false),
    ("held", .winking, false),
]

func drawMenuBarMark(_ eyes: Eyes, asleep: Bool, into context: CGContext) {
    context.setAllowsAntialiasing(true)
    context.setFillColor(ink)
    context.saveGState()
    let scale = (menuBarHeight - menuBarInset * 2) / parts.bounds.height
    // The owl's own extent, centred in the item's box. SVG counts y down the
    // page and a PDF counts it up, so the drawing is flipped as well as
    // scaled, or the owl stands on its head.
    let drawnWidth = parts.bounds.width * scale
    let drawnHeight = parts.bounds.height * scale
    context.translateBy(x: CGFloat((menuBarWidth - drawnWidth) / 2),
                        y: CGFloat(menuBarHeight - (menuBarHeight - drawnHeight) / 2))
    context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
    context.translateBy(x: -parts.bounds.minX, y: -parts.bounds.minY)
    context.addPath(asleep ? drawEyes(eyes).union(sleepMarks) : drawEyes(eyes))
    context.fillPath(using: .winding)
    context.restoreGState()
}

/// Core Graphics stamps every PDF it writes with the time it was written and
/// an id derived from it, so two runs over the same drawing produce two
/// different files. These are committed, so that would dirty all six on every
/// `make mark`. Rewriting both fields, the id from the file's own content,
/// leaves the output a pure function of the masters and this script.
func makeReproducible(_ url: URL) throws {
    var bytes = try Data(contentsOf: url)
    let before = bytes.count

    /// Replaces what lies between `opening` and the next `closing` after it.
    /// The replacement must be the same length as what it replaces: a PDF
    /// carries byte offsets into itself, so moving anything breaks the file.
    func rewrite(after opening: String, until closing: String, with replacement: String, from: Data.Index? = nil) {
        let open = Data(opening.utf8), close = Data(closing.utf8), new = Data(replacement.utf8)
        var cursor = from ?? bytes.startIndex
        while let start = bytes[cursor...].range(of: open),
              let end = bytes[start.upperBound...].range(of: close) {
            let span = bytes.distance(from: start.upperBound, to: end.lowerBound)
            if span == new.count {
                bytes.replaceSubrange(start.upperBound..<end.lowerBound, with: new)
            }
            cursor = bytes.index(start.lowerBound, offsetBy: open.count + span)
        }
    }

    // A fixed instant rather than now. It is not a claim about when the file
    // was made; it is what makes the output reproducible. Both fields are the
    // same length as what Core Graphics writes.
    rewrite(after: "/CreationDate\n(", until: ")", with: "D:20260101000000Z00'00'")
    rewrite(after: "/ModDate (", until: ")", with: "D:20260101000000Z00'00'")

    // The trailer's two id hashes, rewritten only inside the trailer: a bare
    // "<" would match the first one anywhere in the file.
    let blank = String(repeating: "0", count: 32)
    func rewriteIDs(with value: String) {
        guard let trailer = bytes.range(of: Data("/ID [ ".utf8)) else { return }
        rewrite(after: "<", until: ">", with: value, from: trailer.lowerBound)
    }
    rewriteIDs(with: blank)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().prefix(32)
    rewriteIDs(with: String(digest))

    guard bytes.count == before else { throw Failure.pdfLengthChanged }
    try bytes.write(to: url)
}

/// PDF, so one file serves every display scale the menu bar is drawn at, and
/// so it stays a template: shape and alpha only, no colour of its own.
func writeMenuBarMarks() throws {
    for (mark, eyes, asleep) in set {
        let url = markDirectory.appendingPathComponent("MenuBarMark-\(mark).pdf")
        var page = CGRect(x: 0, y: 0, width: menuBarWidth, height: menuBarHeight)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { throw Failure.iconutil }
        context.beginPDFPage(nil)
        drawMenuBarMark(eyes, asleep: asleep, into: context)
        context.endPDFPage()
        context.closePDF()
        try makeReproducible(url)
    }
    print("  Resources/Mark/MenuBarMark-*.pdf  (\(set.count) states of the owl, "
          + "\(menuBarWidth) x \(Int(menuBarHeight)) pt, one width in every mode)")
}

// MARK: The README's pictures

// The README opens with the icon and names the owl, and both are drawn here
// from the same masters as the app's own assets, so the pictures a person
// sees before trying Athina are the ones the app shows once they do.

/// The icon as Finder and the Dock show it, rather than the full bleed square
/// the .icns carries. A page is not masked by macOS, so the picture has to
/// carry the mask, the shadow and the glass the system adds, and the one
/// thing that draws those exactly as Finder does is the system: the new .icns
/// is put in a throwaway bundle and macOS is asked for that bundle's icon.
/// Drawing them here instead would be an imitation that drifts from the real
/// thing with every macOS release, as the Big Sur grid already has.
///
/// The bundle's path is new on every run, so the icon is never one the system
/// cached from an earlier build.
let readmeIconSize = 1024

func writeReadmeIcon() throws {
    let bundle = FileManager.default.temporaryDirectory
        .appendingPathComponent("AthinaReadmeIcon-\(UUID().uuidString).app", isDirectory: true)
    let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundle) }
    try FileManager.default.copyItem(at: root.appendingPathComponent("Resources/AppIcon.icns"),
                                     to: resources.appendingPathComponent("AppIcon.icns"))
    // An app bundle with no executable is drawn with a "cannot open" badge
    // across it, so the bundle carries one that is never run.
    let executable = bundle.appendingPathComponent("Contents/MacOS/stub")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleExecutable": "stub",
                               "CFBundleIconFile": "AppIcon",
                               "CFBundleIdentifier": "com.ahcarpenter.athina.readme-icon"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: bundle.appendingPathComponent("Contents/Info.plist"))

    let icon = NSWorkspace.shared.icon(forFile: bundle.path)
    let size = readmeIconSize
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw Failure.readmeIcon("cannot make a \(size) px bitmap") }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    // A system that did not take the bundle's icon hands back the generic
    // application icon instead, and committing that would put a stranger's
    // picture at the top of the README. The drawing's own ink at the centre
    // of the canvas is what tells the two apart.
    guard let centre = rep.colorAt(x: size / 2, y: size / 2)?.usingColorSpace(.sRGB),
          abs(centre.redComponent - centre.blueComponent) > 0.1 else {
        throw Failure.readmeIcon("macOS did not render the Athina icon for the bundle; nothing was written")
    }
    try rep.representation(using: .png, properties: [:])!
        .write(to: markDirectory.appendingPathComponent("ReadmeIcon.png"))
    print("  Resources/Mark/ReadmeIcon.png  (the icon as this Mac's Finder draws it, \(size) px)")
}

/// The owl, watching, as a vector the README can set beside a line of text,
/// once in each of GitHub's text colours so it reads like the text around it
/// in both themes, the way the menu bar tints its template.
///
/// SVG rather than a bitmap so it is sharp at any size a page draws it, and
/// written out coordinate by coordinate so the file is a pure function of the
/// master and this script.
let readmeOwlInks = [("light", "#1f2328"), ("dark", "#f0f6fc")]

func svgPathData(_ path: CGPath) -> String {
    func n(_ value: CGFloat) -> String {
        let text = String(format: "%.2f", Double(value))
        let trimmed = text.contains(".") ? text.replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression) : text
        return trimmed == "-0" ? "0" : trimmed
    }
    func p(_ point: CGPoint) -> String { "\(n(point.x)) \(n(point.y))" }
    var d: [String] = []
    path.applyWithBlock { pointer in
        let e = pointer.pointee
        switch e.type {
        case .moveToPoint: d.append("M\(p(e.points[0]))")
        case .addLineToPoint: d.append("L\(p(e.points[0]))")
        case .addQuadCurveToPoint: d.append("Q\(p(e.points[0])) \(p(e.points[1]))")
        case .addCurveToPoint: d.append("C\(p(e.points[0])) \(p(e.points[1])) \(p(e.points[2]))")
        case .closeSubpath: d.append("Z")
        @unknown default: break
        }
    }
    return d.joined()
}

func writeReadmeOwls() throws {
    let box = parts.bounds
    var toOrigin = CGAffineTransform(translationX: -box.minX, y: -box.minY)
    let owlPath = drawEyes(.open).copy(using: &toOrigin)!
    let width = String(format: "%.0f", box.width.rounded(.up)), height = String(format: "%.0f", box.height.rounded(.up))
    for (theme, ink) in readmeOwlInks {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(width) \(height)" width="\(width)" height="\(height)">
        <path fill="\(ink)" d="\(svgPathData(owlPath))"/>
        </svg>

        """
        try svg.write(to: markDirectory.appendingPathComponent("ReadmeOwl-\(theme).svg"),
                      atomically: true, encoding: .utf8)
    }
    print("  Resources/Mark/ReadmeOwl-*.svg  (the owl, watching, in GitHub's light and dark text colours)")
}

/// Records what the committed assets were built from: both masters, and this
/// script.
///
/// Core Graphics stamps the running macOS version into every PDF it writes,
/// and the README icon is that macOS's own drawing of the icon, so two
/// machines cannot produce the same bytes and "rebuild and diff" is not a
/// check that can hold. What matters is not the bytes but whether the assets
/// came from the drawing and the drawing code that are in the tree now, and
/// that is what this records: `MarkAssetTests` fails when any of the three has
/// changed and `make mark` has not been run.
///
/// The script is in the record because most of the drawing lives here rather
/// than in the masters: the inset, the eye treatments, the z's and the
/// per-size thickening are all constants in this file, and an edit to any of
/// them leaves the committed assets stale with nothing else to catch it. The
/// output is a pure function of these three on any one Mac, so rerunning
/// after an edit rewrites one line here and leaves the drawn files untouched.
func writeProvenance() throws {
    let generator = URL(fileURLWithPath: #filePath)
    let digest = try [master, owlMaster, generator].map { url -> String in
        let data = try Data(contentsOf: url)
        return url.lastPathComponent + " " + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }.joined(separator: "\n")
    let text = """
    # What Resources/AppIcon.icns, the MenuBarMark PDFs and the README pictures
    # were built from: both masters and the script that drew them. Written by
    # scripts/mark-assets.swift; run `make mark` after changing a master, the
    # script or the variant set, never edit this by hand.
    \(digest)
    variants \(set.map(\.mark).joined(separator: " "))

    """
    try text.write(to: markDirectory.appendingPathComponent("built-from.txt"), atomically: true, encoding: .utf8)
    print("  Resources/Mark/built-from.txt  (both masters and this script recorded)")
}

try writeIcon()
try writeMenuBarMarks()
try writeReadmeIcon()
try writeReadmeOwls()
try writeProvenance()
