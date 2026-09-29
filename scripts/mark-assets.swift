#!/usr/bin/env swift
import AppKit
import CoreGraphics
import CryptoKit
import Foundation

// Builds every asset the app draws its mark from, out of the two committed
// masters: Resources/Mark/AthinaMark.svg, the app icon, and
// Resources/Mark/AthinaGaze.svg, the Gaze, for the menu bar. Run it with
// `make icons` whenever either changes; its outputs are committed so a plain
// `make build` needs nothing but the repository.
//
// It produces:
//
//   Resources/AppIcon.icns           the app icon, every size
//   Resources/Mark/MenuBarMark-*.pdf the menu bar mark, one file per variant
//                                    of MenuBarMark
//   Resources/Mark/ReadmeIcon.png    the app icon as Finder draws it, for the
//                                    top of README.md
//
// Both masters are drawn by macOS's own SVG renderer, which draws vector
// paths into a PDF, and every shape lives in them: this script only picks the
// groups to draw, sizes them and writes the files. Two things about macOS 26
// shape what it does. First, the system masks a legacy .icns to the standard
// app icon shape itself and adds the shadow: a full bleed square here is
// scaled into the 824 of 1024 body and rounded off, in Finder, in the Dock
// and in About. So nothing here draws a rounded rectangle or a shadow of its
// own around the icon. Second, a menu bar extra's image is tinted by the
// system when it is a template, so the menu bar files carry shape and alpha
// only, never colour.

enum Failure: Error {
  case iconutil, pdfLengthChanged
  case svg(String)
  case readmeIcon(String)
}

/// A master, read as XML so that parts of it can be drawn alone.
///
/// Each part is an element with an `id` directly under the root; `drawing`
/// keeps the parts asked for and every element with no `id` (the gradients),
/// and drops the other parts, so the page and its coordinates never change.
struct Master {
  var name: String
  var source: Data
  /// The ids of the root's parts, in document order.
  var parts: [String]
  /// The master's page, its `viewBox`, which the renderer maps onto whatever
  /// rectangle it is drawn into.
  var page: CGRect

  init(contentsOf url: URL) throws {
    name = url.lastPathComponent
    source = try Data(contentsOf: url)
    let root = try XMLDocument(data: source).rootElement()
    parts = (root?.children ?? []).compactMap {
      ($0 as? XMLElement)?.attribute(forName: "id")?.stringValue
    }
    let numbers = root?.attribute(forName: "viewBox")?.stringValue?
      .split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
    guard let n = numbers, n.count == 4 else {
      throw Failure.svg("\(name) carries no viewBox to draw its page from")
    }
    page = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
  }

  /// The master with only `keep` of its parts, ready to draw.
  ///
  /// The representation, not an NSImage around it: an NSImage caches a
  /// bitmap of its own and draws that, a fraction of a pixel off the vector.
  func drawing(of keep: Set<String>) throws -> NSImageRep {
    for id in keep where !parts.contains(id) {
      throw Failure.svg("\(name) has no part \"\(id)\"")
    }
    let document = try XMLDocument(data: source)
    for child in document.rootElement()?.children ?? [] {
      guard let element = child as? XMLElement,
        let id = element.attribute(forName: "id")?.stringValue
      else { continue }
      if !keep.contains(id) { element.detach() }
    }
    guard let rep = NSImage(data: document.xmlData)?.representations.first else {
      throw Failure.svg("macOS could not read \(name)")
    }
    return rep
  }
}

// MARK: Where things are

let root = URL(
  fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".",
  isDirectory: true
)
let markDirectory = root.appendingPathComponent("Resources/Mark", isDirectory: true)
let master = markDirectory.appendingPathComponent("AthinaMark.svg")
let gazeMaster = markDirectory.appendingPathComponent("AthinaGaze.svg")

let icon = try Master(contentsOf: master)
guard icon.parts == ["field", "gaze"] else {
  throw Failure.svg("AthinaMark.svg should be the field and the gaze; found \(icon.parts)")
}

// MARK: The app icon

/// How much larger the Gaze is drawn at each icon size.
///
/// At 16 and 32 px the pupils and the disc's pinch are a pixel or two, so the
/// Gaze grows a little into the field's margin there. Drawing each size to
/// suit itself is what the .icns format exists to allow; it is optical sizing,
/// not a different drawing.
func gazeScale(for size: Int) -> Double {
  switch size {
  case ...16: 1.14
  case 17...32: 1.08
  default: 1
  }
}

func drawIcon(size: Int) throws -> CGImage {
  // 8-bit sRGB with premultiplied alpha is a format bitmap contexts support,
  // and every size drawn is positive, so neither this nor the sRGB space fails.
  let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  let canvas = Double(size)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
  try icon.drawing(of: ["field"]).draw(in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
  // The Gaze sits a little above the field, lifted by a soft shadow straight
  // down, the one depth the icon draws itself.
  context.setShadow(
    offset: CGSize(width: 0, height: -canvas * 0.014),
    blur: canvas * 0.035,
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.3)
  )
  // One transparency layer, so the Gaze casts one shadow as a whole rather
  // than every iris and pupil casting its own onto the disc.
  context.beginTransparencyLayer(auxiliaryInfo: nil)
  let drawn = canvas * gazeScale(for: size)
  try icon.drawing(of: ["gaze"]).draw(
    in: CGRect(x: (canvas - drawn) / 2, y: (canvas - drawn) / 2, width: drawn, height: drawn)
  )
  context.endTransparencyLayer()
  NSGraphicsContext.restoreGraphicsState()
  // A bitmap context always has an image to make.
  return context.makeImage()!
}

func writeIcon() throws {
  let iconset = markDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
  try? FileManager.default.removeItem(at: iconset)
  try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
  // Every size the .icns format carries, each drawn from the vector rather
  // than resampled from a larger bitmap, so none of them is soft.
  let sizes: [(String, Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
  ]
  for (name, pixels) in sizes {
    let rep = NSBitmapImageRep(cgImage: try drawIcon(size: pixels))
    // A bitmap made from a CGImage always encodes as PNG.
    try rep.representation(using: .png, properties: [:])!.write(
      to: iconset.appendingPathComponent("\(name).png")
    )
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
  process.arguments = [
    "--convert",
    "icns",
    "--output",
    root.appendingPathComponent("Resources/AppIcon.icns").path,
    iconset.path,
  ]
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { throw Failure.iconutil }
  try FileManager.default.removeItem(at: iconset)
  print("  Resources/AppIcon.icns  (\(sizes.count) sizes, the Gaze on its field)")
}

// MARK: The menu bar mark

// The menu bar shows the Gaze: two eyes drawn as one line, bold enough to sit
// among the bar's other extras at 16 points. Its states are made out of the
// eyes rather than hung off them, since the eyes are what watching means: the
// outline never changes, and the item keeps ONE width in every mode.

let gaze = try Master(contentsOf: gazeMaster)

/// The states, in the order the master draws them.
///
/// Changing this list, and the master's groups with it, is the whole of
/// changing the set: the modes, their names and the resolution that picks
/// between them live in `MenuBarMark` and do not move.
let set = ["watching", "idle", "paused", "excluded", "needsSomething", "held"]
guard gaze.parts == ["outline"] + set else {
  throw Failure.svg(
    "AthinaGaze.svg should be the outline and one group per state, \(set); found \(gaze.parts)"
  )
}

/// The item's box in points: the height the menu bar gives a symbol, and the
/// Gaze's width at the height it is drawn, rounded up to a half point.
///
/// The drawing is held off the top and bottom of that box by `menuBarInset`,
/// so the item sits inside its box the way the system's own extras do rather
/// than reading as the tallest thing in the bar. Every state is drawn at the
/// same scale in the same box, so the item is one width in every mode.
let menuBarHeight = 16.0
let menuBarInset = 1.5
let menuBarDrawn = CGSize(
  width: (menuBarHeight - menuBarInset * 2) * gaze.page.width / gaze.page.height,
  height: menuBarHeight - menuBarInset * 2
)
let menuBarWidth = (menuBarDrawn.width * 2).rounded(.up) / 2

/// Core Graphics stamps every PDF it writes with the time it was written and an
/// id derived from it, so two runs over the same drawing produce two different
/// files.
///
/// These are committed, so that would dirty all six on every `make icons`.
/// Rewriting both fields, the id from the file's own content, leaves the output
/// a pure function of the masters and this script.
func makeReproducible(_ url: URL) throws {
  var bytes = try Data(contentsOf: url)
  let before = bytes.count

  /// Replaces what lies between `opening` and the next `closing` after it.
  /// The replacement must be the same length as what it replaces: a PDF
  /// carries byte offsets into itself, so moving anything breaks the file.
  func rewrite(
    after opening: String,
    until closing: String,
    with replacement: String,
    from: Data.Index? = nil
  ) {
    let open = Data(opening.utf8)
    let close = Data(closing.utf8)
    let new = Data(replacement.utf8)
    var cursor = from ?? bytes.startIndex
    while let start = bytes[cursor...].range(of: open),
      let end = bytes[start.upperBound...].range(of: close)
    {
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
  for mark in set {
    let url = markDirectory.appendingPathComponent("MenuBarMark-\(mark).pdf")
    var page = CGRect(x: 0, y: 0, width: menuBarWidth, height: menuBarHeight)
    guard let consumer = CGDataConsumer(url: url as CFURL),
      let context = CGContext(consumer: consumer, mediaBox: &page, nil)
    else { throw Failure.iconutil }
    context.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    try gaze.drawing(of: ["outline", mark]).draw(
      in: CGRect(
        x: (menuBarWidth - menuBarDrawn.width) / 2,
        y: menuBarInset,
        width: menuBarDrawn.width,
        height: menuBarDrawn.height
      )
    )
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    context.closePDF()
    try makeReproducible(url)
  }
  print(
    "  Resources/Mark/MenuBarMark-*.pdf  (\(set.count) states of the Gaze, "
      + "\(menuBarWidth) x \(Int(menuBarHeight)) pt, one width in every mode)"
  )
}

// MARK: The README's icon

// The README opens with the icon, drawn here from the same master as the
// app's own assets, so the picture a person sees before trying Athina is the
// one the app shows once they do.

/// The icon as Finder and the Dock show it, rather than the full bleed square
/// the .icns carries.
///
/// A page is not masked by macOS, so the picture has to carry the mask, the
/// shadow and the glass the system adds, and the one thing that draws those
/// exactly as Finder does is the system: the new .icns is put in a throwaway
/// bundle and macOS is asked for that bundle's icon. Drawing them here instead
/// would be an imitation that drifts from the real thing with every macOS
/// release, as the Big Sur grid already has.
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
  try FileManager.default.copyItem(
    at: root.appendingPathComponent("Resources/AppIcon.icns"),
    to: resources.appendingPathComponent("AppIcon.icns")
  )
  // An app bundle with no executable is drawn with a "cannot open" badge
  // across it, so the bundle carries one that is never run.
  let executable = bundle.appendingPathComponent("Contents/MacOS/stub")
  try FileManager.default.createDirectory(
    at: executable.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data("#!/bin/sh\n".utf8).write(to: executable)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
  let info: [String: Any] = [
    "CFBundlePackageType": "APPL",
    "CFBundleExecutable": "stub",
    "CFBundleIconFile": "AppIcon",
    "CFBundleIdentifier": "com.ahcarpenter.athina.readme-icon",
  ]
  try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    .write(to: bundle.appendingPathComponent("Contents/Info.plist"))

  let rep = try readmeBitmap(of: NSWorkspace.shared.icon(forFile: bundle.path))

  // A system that did not take the bundle's icon hands back the generic
  // application icon instead, and committing that would put a stranger's
  // picture at the top of the README. So the generic icon is drawn the same
  // way and the render is refused when it is that picture.
  let generic = try readmeBitmap(of: NSWorkspace.shared.icon(for: .applicationBundle))
  guard !samePicture(rep, generic) else {
    throw Failure.readmeIcon(
      "macOS did not render the Athina icon for the bundle; nothing was written"
    )
  }
  // A bitmap `readmeBitmap` drew always encodes as PNG.
  try rep.representation(using: .png, properties: [:])!
    .write(to: markDirectory.appendingPathComponent("ReadmeIcon.png"))
  print(
    """
      Resources/Mark/ReadmeIcon.png  (the icon as this Mac's Finder draws it, \
    \(readmeIconSize) px)
    """
  )
}

/// An icon drawn into a new bitmap the size of the README icon.
func readmeBitmap(of icon: NSImage) throws -> NSBitmapImageRep {
  let size = readmeIconSize
  guard
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: size,
      pixelsHigh: size,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )
  else { throw Failure.readmeIcon("cannot make a \(size) px bitmap") }
  rep.size = NSSize(width: size, height: size)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
  NSGraphicsContext.restoreGraphicsState()
  return rep
}

/// Whether two bitmaps from `readmeBitmap` show the same picture: nine in ten
/// pixels or more within 2 of 255 of each other in every channel.
///
/// The generic icon matches itself in every pixel, and the Athina icon matches
/// it in about a third, the clear margin both share.
func samePicture(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
  // `readmeBitmap` makes each rep with its own buffer, so both have data.
  let pa = a.bitmapData!
  let pb = b.bitmapData!
  var matching = 0
  for y in 0..<a.pixelsHigh {
    for x in 0..<a.pixelsWide {
      let i = y * a.bytesPerRow + x * 4
      if (0..<4).allSatisfy({ abs(Int(pa[i + $0]) - Int(pb[i + $0])) <= 2 }) { matching += 1 }
    }
  }
  return matching * 10 >= a.pixelsWide * a.pixelsHigh * 9
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
/// changed and `make icons` has not been run.
///
/// The script is in the record because it still decides how the masters are
/// drawn: the icon's per-size scale and shadow, and the menu bar's box and
/// inset are constants in this file, and an edit to any of them leaves the
/// committed assets stale with nothing else to catch it. The output is a pure
/// function of these three on any one Mac, so rerunning after an edit
/// rewrites one line here and leaves the drawn files untouched.
func writeProvenance() throws {
  let generator = URL(fileURLWithPath: #filePath)
  let digest = try [master, gazeMaster, generator].map { url -> String in
    let data = try Data(contentsOf: url)
    return url.lastPathComponent + " "
      + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }.joined(separator: "\n")
  let text = """
    # What Resources/AppIcon.icns, the MenuBarMark PDFs and the README icon
    # were built from: both masters and the script that drew them. Written by
    # scripts/mark-assets.swift; run `make icons` after changing a master, the
    # script or the variant set, never edit this by hand.
    \(digest)
    variants \(set.joined(separator: " "))

    """
  try text.write(
    to: markDirectory.appendingPathComponent("built-from.txt"),
    atomically: true,
    encoding: .utf8
  )
  print("  Resources/Mark/built-from.txt  (both masters and this script recorded)")
}

try writeIcon()
try writeMenuBarMarks()
try writeReadmeIcon()
try writeProvenance()
