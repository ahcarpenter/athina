#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Builds every asset the app draws the mark from, out of the one master
// source, Resources/Mark/MentorMark.svg. Run it with `make mark` whenever that
// file changes; its outputs are committed so a plain `make build` needs
// nothing but the repository.
//
// It produces:
//
//   Resources/AppIcon.icns           the app icon, full artwork, every size
//   Resources/Mark/MenuBarMark-*.pdf the menu bar mark, line art alone, one
//                                    file per variant of MenuBarMark
//
// Two things about macOS 26 shape what it does. First, the system masks a
// legacy .icns to the standard app icon shape itself and adds the shadow: a
// full bleed square here is scaled into the 824 of 1024 body and rounded off,
// in Finder, in the Dock and in About. So nothing here draws a rounded
// rectangle or a shadow of its own. Second, a menu bar extra's image is
// tinted by the system when it is a template, so the menu bar files carry
// shape and alpha only, never colour.

/// A small reader for the subset of SVG this project's mark uses: groups with
/// transforms, paths, and the three primitives the cream layer is made of.
/// Enough to rasterise the committed master source, and no more.
enum SVG {
    struct Element {
        var path: CGPath
        var fill: CGColor?
        var evenOdd: Bool
        var group: String?
    }

    struct Document {
        var viewBox: CGRect
        var elements: [Element]
    }

    static func parse(contentsOf url: URL) throws -> Document {
        let text = try String(contentsOf: url, encoding: .utf8)
        let viewBox = attribute("viewBox", in: firstTag("svg", in: text) ?? "").map { value -> CGRect in
            let n = numbers(value)
            return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        } ?? CGRect(x: 0, y: 0, width: 1, height: 1)

        var elements: [Element] = []
        var transforms: [CGAffineTransform] = [.identity]
        var fills: [CGColor?] = [CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
        var groups: [String?] = [nil]

        for token in tags(in: text) {
            let name = tagName(token)
            let closing = token.hasPrefix("</")
            let selfClosing = token.hasSuffix("/>")
            if name == "g" {
                if closing {
                    if transforms.count > 1 { transforms.removeLast(); fills.removeLast(); groups.removeLast() }
                    continue
                }
                let t = attribute("transform", in: token).map(transform) ?? .identity
                transforms.append(t.concatenating(transforms.last!))
                fills.append(attribute("fill", in: token).map(colour) ?? fills.last!)
                groups.append(attribute("id", in: token) ?? groups.last!)
                if selfClosing { transforms.removeLast(); fills.removeLast(); groups.removeLast() }
                continue
            }
            guard !closing else { continue }
            var local = transforms.last!
            if let own = attribute("transform", in: token) { local = transform(own).concatenating(local) }
            let fill = attribute("fill", in: token).map(colour) ?? fills.last!
            let evenOdd = attribute("fill-rule", in: token) == "evenodd"
            var built: CGMutablePath?
            switch name {
            case "path":
                if let d = attribute("d", in: token) { built = pathData(d) }
            case "circle":
                let cx = number("cx", token), cy = number("cy", token), r = number("r", token)
                let p = CGMutablePath()
                p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                built = p
            case "rect":
                let p = CGMutablePath()
                p.addRect(CGRect(x: number("x", token), y: number("y", token),
                                 width: number("width", token), height: number("height", token)))
                built = p
            case "polygon":
                if let points = attribute("points", in: token) {
                    let n = numbers(points)
                    let p = CGMutablePath()
                    for i in stride(from: 0, to: n.count - 1, by: 2) {
                        let pt = CGPoint(x: n[i], y: n[i + 1])
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                    p.closeSubpath()
                    built = p
                }
            default: continue
            }
            guard let built else { continue }
            let transformed = CGMutablePath()
            transformed.addPath(built, transform: local)
            elements.append(Element(path: transformed, fill: fill, evenOdd: evenOdd, group: groups.last!))
        }
        return Document(viewBox: viewBox, elements: elements)
    }

    /// Renders at a pixel width, keeping the viewBox's aspect. `group` limits
    /// the drawing to one named group; `tint` overrides every fill, which is
    /// how a template image is produced.
    static func render(
        _ document: Document, pixelWidth: Int, group: String? = nil,
        background: CGColor? = nil, tint: CGColor? = nil
    ) -> CGImage {
        let scale = Double(pixelWidth) / document.viewBox.width
        let pixelHeight = Int((document.viewBox.height * scale).rounded())
        let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        if let background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .high
        // SVG's y runs down the page; Core Graphics' runs up.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
        context.translateBy(x: -document.viewBox.minX, y: -document.viewBox.minY)
        for element in document.elements {
            if let group, element.group != group { continue }
            guard let fill = tint ?? element.fill else { continue }
            context.addPath(element.path)
            context.setFillColor(fill)
            context.fillPath(using: element.evenOdd ? .evenOdd : .winding)
        }
        return context.makeImage()!
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    // MARK: Reading

    private static func tags(in text: String) -> [String] {
        var found: [String] = []
        var current = ""
        var inside = false
        for character in text {
            if character == "<" { inside = true; current = "<" }
            else if character == ">" && inside { current.append(">"); found.append(current); inside = false }
            else if inside { current.append(character) }
        }
        return found
    }

    private static func tagName(_ token: String) -> String {
        var name = ""
        for character in token.dropFirst() {
            if character == "/" && name.isEmpty { continue }
            if character.isWhitespace || character == ">" || character == "/" { break }
            name.append(character)
        }
        return name
    }

    private static func firstTag(_ name: String, in text: String) -> String? {
        tags(in: text).first { tagName($0) == name }
    }

    private static func attribute(_ name: String, in token: String) -> String? {
        guard let range = token.range(of: "\(name)=\"") else { return nil }
        let rest = token[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func number(_ name: String, _ token: String) -> Double {
        attribute(name, in: token).flatMap(Double.init) ?? 0
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

    private static func transform(_ text: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "(") {
            let name = text[index..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\n\t"))
            guard let close = text[open...].firstIndex(of: ")") else { break }
            let n = numbers(String(text[text.index(after: open)..<close]))
            var step = CGAffineTransform.identity
            switch name {
            case "translate": step = CGAffineTransform(translationX: n[0], y: n.count > 1 ? n[1] : 0)
            case "scale": step = CGAffineTransform(scaleX: n[0], y: n.count > 1 ? n[1] : n[0])
            case "matrix": step = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
            case "rotate": step = CGAffineTransform(rotationAngle: n[0] * .pi / 180)
            default: break
            }
            result = step.concatenating(result)
            index = text.index(after: close)
        }
        return result
    }

    private static func pathData(_ d: String) -> CGMutablePath {
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
                if i < tokens.count, tokens[i].count == 1, tokens[i].first!.isLetter { } else { i += 0 }
                if i < tokens.count, !(tokens[i].count == 1 && tokens[i].first!.isLetter) { }
                // Nothing follows a close but the next command.
                if i < tokens.count, let c = tokens[i].first, !c.isLetter { i += 1 }
            default:
                i += 1
            }
        }
        return path
    }
}

// MARK: Where things are

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", isDirectory: true)
let master = root.appendingPathComponent("Resources/Mark/MentorMark.svg")
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

enum Failure: Error { case iconutil }

// MARK: The menu bar mark

// The menu bar shows the line art alone, with no cream shapes behind it.
//
// The whole drawing does not survive 16 points. At its own proportions it is
// 11 points wide, and its stroke lands on half a pixel, so the crest and the
// face grey into one another. What is drawn instead is the helmeted head: the
// part of the drawing that is a complete subject on its own, cropped where no
// stroke is cut part way through, at a weight set for this size the way SF
// Symbols are drawn per optical size rather than scaled up and down.

/// The region of the master the menu bar draws, in its coordinates. Its left
/// edge sits right of the crest's trailing line, so nothing is cut mid stroke.
let crop = CGRect(x: 235, y: 470, width: 581, height: 731)

/// Stroke weight added for this size, in the master's units.
let menuBarThicken = 10.0

/// The item's height in points, the size the menu bar gives a symbol.
let menuBarHeight = 16.0
/// The drawing's width at that height, from the crop's own proportions.
let drawingWidth = (menuBarHeight * crop.width / crop.height).rounded()
/// A lane beside the drawing that only a badge ever occupies. Every variant
/// reserves it, watching included, so the mark is never covered and the item
/// keeps ONE width in every mode: the menu bar's other extras never shift
/// sideways when Mentor's state changes.
let badgeLane = 6.0
let menuBarWidth = drawingWidth + badgeLane

/// What distinguishes a variant of the mark. The drawing itself never changes.
///
/// Changing this table is the whole of changing the set: the modes, their
/// names and the resolution that picks between them live in
/// `MenuBarMark` and do not move.
enum Badge: String {
    case none, moon, slash, noEntry, exclamation, pause
}

let set: [(mark: String, badge: Badge)] = [
    ("watching", .none),
    ("idle", .moon),
    ("paused", .slash),
    ("excluded", .noEntry),
    ("needsSomething", .exclamation),
    ("held", .pause),
]

/// Draws one variant into a context already sized in points.
///
/// Every shape here is made by clipping rather than by erasing: a PDF has no
/// notion of clearing pixels that are already down, so a blend mode that works
/// on a bitmap silently does nothing in the file the app actually loads.
func drawMenuBarMark(_ badge: Badge, into context: CGContext) {
    context.setAllowsAntialiasing(true)
    context.setFillColor(ink)
    context.setStrokeColor(ink)
    let box = CGRect(x: 0, y: 0, width: menuBarWidth, height: menuBarHeight)

    /// Clips to everything outside `shape`, so what is drawn next appears to
    /// have had a margin taken out of it.
    func clippingOutside(_ shape: CGPath, _ body: () -> Void) {
        context.saveGState()
        context.addRect(box.insetBy(dx: -menuBarWidth, dy: -menuBarHeight))
        context.addPath(shape)
        context.clip(using: .evenOdd)
        body()
        context.restoreGState()
    }

    // A slash is the one variant drawn across the drawing rather than beside
    // it, because "not watching at all" is the state that has to read at a
    // glance. It stays inside the drawing's own box, and the drawing keeps a
    // clear margin around it, the way a slashed SF Symbol does.
    let inset = menuBarHeight * 0.08
    let slash = CGMutablePath()
    slash.move(to: CGPoint(x: inset, y: inset))
    slash.addLine(to: CGPoint(x: drawingWidth - inset, y: menuBarHeight - inset))
    let slashWidth = menuBarHeight * 0.115
    let gap = slash.copy(strokingWithWidth: CGFloat(slashWidth + menuBarHeight * 0.13),
                         lineCap: .round, lineJoin: .round, miterLimit: 10)

    func drawDrawing() {
        context.saveGState()
        let scale = menuBarHeight / crop.height
        context.translateBy(x: 0, y: CGFloat(menuBarHeight))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
        context.translateBy(x: -crop.minX, y: -crop.minY)
        context.clip(to: crop)
        for element in document.elements where element.group == "lineart" {
            context.addPath(element.path)
            context.fillPath(using: element.evenOdd ? .evenOdd : .winding)
            context.addPath(element.path)
            context.setLineWidth(CGFloat(menuBarThicken))
            context.setLineJoin(.round)
            context.strokePath()
        }
        context.restoreGState()
    }

    if badge == .slash {
        clippingOutside(gap) { drawDrawing() }
        context.setLineWidth(CGFloat(slashWidth))
        context.setLineCap(.round)
        context.addPath(slash)
        context.strokePath()
        return
    }
    drawDrawing()
    guard badge != .none else { return }

    // Everything else sits in the reserved lane, aligned low the way an SF
    // Symbols badge sits under its symbol.
    let side = badgeLane - 1
    let cell = CGRect(x: drawingWidth + 0.5, y: menuBarHeight * 0.06, width: side, height: side)
    let centre = CGPoint(x: cell.midX, y: cell.midY)
    switch badge {
    case .moon:
        // A disc with a second disc taken out of it, which keeps its crescent
        // at five points where a drawn moon would not.
        let bite = CGPath(ellipseIn: CGRect(x: centre.x - side * 0.16, y: centre.y - side * 0.40,
                                            width: side * 0.92, height: side * 0.92), transform: nil)
        clippingOutside(bite) {
            context.fillEllipse(in: CGRect(x: centre.x - side * 0.5, y: centre.y - side * 0.5,
                                           width: side, height: side))
        }
    case .noEntry:
        let radius = side * 0.5
        let bar = CGPath(rect: CGRect(x: centre.x - radius * 0.58, y: centre.y - radius * 0.20,
                                      width: radius * 1.16, height: radius * 0.40), transform: nil)
        clippingOutside(bar) {
            context.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                           width: radius * 2, height: radius * 2))
        }
    case .exclamation:
        let barWidth = side * 0.26
        context.fill(CGRect(x: centre.x - barWidth / 2, y: centre.y - side * 0.10,
                            width: barWidth, height: side * 0.60))
        context.fillEllipse(in: CGRect(x: centre.x - barWidth / 2, y: centre.y - side * 0.48,
                                       width: barWidth, height: barWidth))
    case .pause:
        let barWidth = side * 0.26, between = side * 0.24
        context.fill(CGRect(x: centre.x - between / 2 - barWidth, y: centre.y - side * 0.46,
                            width: barWidth, height: side * 0.92))
        context.fill(CGRect(x: centre.x + between / 2, y: centre.y - side * 0.46,
                            width: barWidth, height: side * 0.92))
    case .none, .slash:
        break
    }
}

/// PDF, so one file serves every display scale the menu bar is drawn at, and
/// so it stays a template: shape and alpha only, no colour of its own.
func writeMenuBarMarks() throws {
    for (mark, badge) in set {
        let url = markDirectory.appendingPathComponent("MenuBarMark-\(mark).pdf")
        var box = CGRect(x: 0, y: 0, width: menuBarWidth, height: menuBarHeight)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw Failure.iconutil }
        context.beginPDFPage(nil)
        drawMenuBarMark(badge, into: context)
        context.endPDFPage()
        context.closePDF()
    }
    print("  Resources/Mark/MenuBarMark-*.pdf  (\(set.count) variants, \(Int(menuBarWidth)) x \(Int(menuBarHeight)) pt, one width in every mode)")
}

try writeIcon()
try writeMenuBarMarks()
