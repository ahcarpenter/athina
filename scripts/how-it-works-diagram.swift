#!/usr/bin/env swift
import Foundation

// Draws the How it works diagram at the top of README.md's section of that
// name, in a light and a dark form:
//
//   docs/images/how-it-works-light.svg
//   docs/images/how-it-works-dark.svg
//
// Run it with `make diagram` after changing it; its outputs are committed and
// never edited by hand. The diagram is Athina's own flow, drawn in the mark's
// colours (docs/design.md): the flat cream circle, square and hexagon of
// Resources/Mark/AthinaMark.svg stand for sensing, triage and mentor, and the
// menu bar owl is read from Resources/Mark/AthinaOwl.svg, so it is the same
// drawing the menu bar shows. Everything above the dashed line stays on the
// Mac; what crosses it is what a model call carries.

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")

enum Failure: Error { case owl(String) }

/// The owl master's one path, as the menu bar draws it.
func owlPath() throws -> (d: String, width: Double, height: Double) {
  let url = root.appendingPathComponent("Resources/Mark/AthinaOwl.svg")
  let svg = try XMLDocument(contentsOf: url).rootElement()
  let paths = svg?.children?.compactMap { $0 as? XMLElement }.filter { $0.name == "path" } ?? []
  guard paths.count == 1, let d = paths[0].attribute(forName: "d")?.stringValue,
    let box = svg?.attribute(forName: "viewBox")?.stringValue
  else { throw Failure.owl("the owl master should be one <path> with a viewBox") }
  let numbers = box.split(separator: " ").compactMap { Double($0) }
  guard numbers.count == 4 else { throw Failure.owl("unreadable viewBox \(box)") }
  return (d, numbers[2], numbers[3])
}

/// The two appearances.
///
/// Ink and cream are the mark's own, sampled from the drawing; the callout stroke is the system accent, as the real callout's is.
struct Theme {
  let name: String
  let ink: String  // strokes, titles and the owl
  let text: String  // body text
  let muted: String  // band labels, arrow labels
  let card: String
  let band: String  // the Mac band's fill
  let cream: String  // the mark's shapes
  let accent: String

  static let light = Theme(
    name: "light",
    ink: "#332C2B",
    text: "#4A413F",
    muted: "#6E6361",
    card: "#FFFDF8",
    band: "#F1DEB7",
    cream: "#F1DEB7",
    accent: "#007AFF"
  )
  static let dark = Theme(
    name: "dark",
    ink: "#F1DEB7",
    text: "#E4D6BC",
    muted: "#B9AC96",
    card: "#2A2423",
    band: "#3A3230",
    cream: "#F1DEB7",
    accent: "#0A84FF"
  )
}

let font =
  "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, sans-serif"

func escape(_ s: String) -> String {
  s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
}

/// Lines of text starting at a baseline, one line every `leading` units.
func lines(
  _ texts: [String],
  x: Double,
  y: Double,
  size: Double,
  leading: Double,
  fill: String,
  weight: Int = 400,
  anchor: String = "start"
) -> String {
  texts.enumerated().map { i, t in
    "<text x=\"\(x)\" y=\"\(y + Double(i) * leading)\" font-size=\"\(size)\" "
      + "font-weight=\"\(weight)\" fill=\"\(fill)\" text-anchor=\"\(anchor)\">\(escape(t))</text>"
  }.joined(separator: "\n")
}

func hexagon(cx: Double, cy: Double, r: Double) -> String {
  (0..<6).map { i -> String in
    let a = Double.pi / 3 * Double(i) - Double.pi / 2
    return String(format: "%.2f,%.2f", cx + r * cos(a), cy + r * sin(a))
  }.joined(separator: " ")
}

func arrow(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ t: Theme) -> String {
  "<line x1=\"\(x1)\" y1=\"\(y1)\" x2=\"\(x2)\" y2=\"\(y2)\" stroke=\"\(t.ink)\" "
    + "stroke-width=\"3\" marker-end=\"url(#head)\"/>"
}

/// A stage: a card with the mark's shape beside its title and a few lines
/// under it.
func card(
  x: Double,
  y: Double,
  w: Double,
  h: Double,
  shape: String,
  title: String,
  body: [String],
  model: String? = nil,
  _ t: Theme
) -> String {
  let sx = x + 38
  let sy = y + 44
  let motif: String
  switch shape {
  case "circle": motif = "<circle cx=\"\(sx)\" cy=\"\(sy)\" r=\"17\" fill=\"\(t.cream)\"/>"
  case "square":
    motif =
      "<rect x=\"\(sx - 15)\" y=\"\(sy - 15)\" width=\"30\" height=\"30\" fill=\"\(t.cream)\"/>"
  case "hexagon":
    motif = "<polygon points=\"\(hexagon(cx: sx, cy: sy, r: 18))\" fill=\"\(t.cream)\"/>"
  default: motif = ""
  }
  return """
    <rect x="\(x)" y="\(y)" width="\(w)" height="\(h)" rx="18" fill="\(t.card)" stroke="\(t.ink)" stroke-width="2.5"/>
    \(motif)
    \(lines([title], x: x + 68, y: y + 54, size: 30, leading: 0, fill: t.ink, weight: 600))
    \(lines(body, x: x + 24, y: y + 104, size: 22, leading: 30, fill: t.text))
    \(lines(model.map { [$0] } ?? [], x: x + 24, y: y + h - 28, size: 22, leading: 0, fill: t.muted))
    """
}

func diagram(_ t: Theme, owl: (d: String, width: Double, height: Double)) -> String {
  let width = 1280.0
  let bottomY = 450.0
  let ch = 230.0
  let height = bottomY + ch + 24
  let (c1, c2, c3) = (40.0, 490.0, 940.0)
  let cw = 300.0
  let topY = 92.0

  // What you are doing: a small window with lines of text in it.
  let window = """
    <rect x="\(c1 + 24)" y="\(topY + 116)" width="252" height="76" rx="8" fill="none" stroke="\(t.ink)" stroke-width="2"/>
    <line x1="\(c1 + 24)" y1="\(topY + 134)" x2="\(c1 + 276)" y2="\(topY + 134)" stroke="\(t.ink)" stroke-width="2"/>
    \((0..<3).map { "<circle cx=\"\(c1 + 38 + Double($0) * 13)\" cy=\"\(topY + 125)\" r=\"3.5\" fill=\"\(t.ink)\"/>" }.joined())
    <rect x="\(c1 + 40)" y="\(topY + 148)" width="170" height="7" rx="3.5" fill="\(t.muted)"/>
    <rect x="\(c1 + 40)" y="\(topY + 164)" width="210" height="7" rx="3.5" fill="\(t.muted)"/>
    """

  // The note: the menu bar with the owl, the note hanging under it, and a
  // callout outlining a line of text on screen.
  let owlScale = 28.0 / owl.height
  let owlX = c3 + cw - 64
  let note = """
    <rect x="\(c3 + 24)" y="\(topY + 76)" width="252" height="34" rx="6" fill="\(t.band)" stroke="\(t.ink)" stroke-width="2"/>
    <g transform="translate(\(owlX) \(topY + 79)) scale(\(String(format: "%.4f", owlScale)))"><path d="\(owl.d)" fill="\(t.ink)"/></g>
    <rect x="\(c3 + 104)" y="\(topY + 118)" width="172" height="44" rx="12" fill="\(t.card)" stroke="\(t.ink)" stroke-width="2"/>
    <rect x="\(c3 + 118)" y="\(topY + 131)" width="120" height="7" rx="3.5" fill="\(t.ink)"/>
    <rect x="\(c3 + 118)" y="\(topY + 145)" width="90" height="6" rx="3" fill="\(t.muted)"/>
    <rect x="\(c3 + 40)" y="\(topY + 181)" width="110" height="7" rx="3.5" fill="\(t.muted)"/>
    <rect x="\(c3 + 30)" y="\(topY + 171)" width="130" height="27" rx="6" fill="none" stroke="\(t.accent)" stroke-width="3"/>
    <text x="\(c3 + 170)" y="\(topY + 191)" font-size="20" fill="\(t.accent)" font-weight="600">callout</text>
    """

  let dashY = topY + ch + 58
  let labelY = dashY + 34
  return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- Generated by scripts/how-it-works-diagram.swift (make diagram); do not edit by hand. -->
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(Int(width)) \(Int(height))" width="\(Int(width))" height="\(Int(height))" font-family="\(font)">
    <title>How Athina works</title>
    <defs>
      <marker id="head" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="5" markerHeight="5" orient="auto-start-reverse">
        <path d="M0,0 L10,5 L0,10 z" fill="\(t.ink)"/>
      </marker>
    </defs>

    <rect x="12" y="12" width="\(width - 24)" height="\(topY + ch + 30 - 12)" rx="26" fill="\(t.band)" fill-opacity="0.45"/>
    \(lines(["ON YOUR MAC"], x: 40, y: 62, size: 22, leading: 0, fill: t.muted, weight: 700))
    \(lines(["nothing is sensed before Allow, while paused, or on an excluded app"], x: width - 40, y: 62, size: 22, leading: 0, fill: t.muted, anchor: "end"))

    <line x1="12" y1="\(dashY)" x2="\(width - 12)" y2="\(dashY)" stroke="\(t.muted)" stroke-width="2" stroke-dasharray="10 8"/>
    \(lines(["TO YOUR MODEL PROVIDER, WITH YOUR OWN KEY"], x: 40, y: bottomY - 22, size: 22, leading: 0, fill: t.muted, weight: 700))

    \(card(x: c1, y: topY, w: cw, h: ch, shape: "", title: "", body: [], t))
    \(lines(["What you are doing"], x: c1 + 24, y: topY + 54, size: 30, leading: 0, fill: t.ink, weight: 600))
    \(lines(["the app in front, its window"], x: c1 + 24, y: topY + 94, size: 22, leading: 0, fill: t.text))
    \(window)

    \(card(x: c2, y: topY, w: cw, h: ch, shape: "circle", title: "Sensing", body: ["read on this Mac and", "kept in a local journal,", "the screen text by OCR"], t))

    \(card(x: c3, y: topY, w: cw, h: ch, shape: "", title: "", body: [], t))
    \(lines(["A note"], x: c3 + 24, y: topY + 54, size: 30, leading: 0, fill: t.ink, weight: 600))
    \(note)

    \(card(x: c2, y: bottomY, w: cw, h: ch, shape: "square", title: "Triage", body: ["the cheap model asks:", "is this worth a look?"], model: "Haiku 4.5 by default", t))
    \(card(x: c3, y: bottomY, w: cw, h: ch, shape: "hexagon", title: "Mentor", body: ["the strong model reads", "recent screen text and", "a thumbnail"], model: "Opus 5 by default", t))

    \(lines(["Every call counts", "against the hourly", "spend cap, $1 by", "default."], x: c1 + 24, y: bottomY + 54, size: 22, leading: 32, fill: t.text))

    \(arrow(c1 + cw + 8, topY + ch / 2, c2 - 10, topY + ch / 2, t))
    \(arrow(c2 + cw / 2, topY + ch + 8, c2 + cw / 2, bottomY - 10, t))
    \(lines(["screen text,", "at a change"], x: c2 + cw / 2 + 18, y: labelY, size: 22, leading: 28, fill: t.muted))
    \(arrow(c2 + cw + 8, bottomY + ch / 2, c3 - 10, bottomY + ch / 2, t))
    \(lines(["worth", "a look"], x: c2 + cw + 75, y: bottomY + ch / 2 - 44, size: 22, leading: 26, fill: t.muted, anchor: "middle"))
    \(arrow(c3 + cw / 2, bottomY - 8, c3 + cw / 2, topY + ch + 10, t))
    \(lines(["a suggestion,", "or nothing"], x: c3 + cw / 2 + 18, y: labelY, size: 22, leading: 28, fill: t.muted))
    </svg>

    """
}

let owl = try owlPath()
let out = root.appendingPathComponent("docs/images")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for theme in [Theme.light, Theme.dark] {
  let file = out.appendingPathComponent("how-it-works-\(theme.name).svg")
  try diagram(theme, owl: owl).write(to: file, atomically: true, encoding: .utf8)
  print("wrote \(file.path)")
}
