import CoreGraphics
import CoreText
import Foundation

/// What a hermetic run's sensing is shown in place of the Mac's screen: one
/// app's window in front, filling a display, with a text area holding `text`
/// focused, as a document in an editor is.
///
/// The control API's `observe` scripts it (docs/e2e.md "Scripted sensing"), and
/// `SensingPipeline.observe(_:)` journals it the way a capture of that window
/// is journaled: the app or window switch it makes, then an observation whose
/// frame is the text drawn a line at a time and whose recognised text is those
/// lines, so no screen is read and no text recognition runs.
public struct ScriptedObservation: Equatable, Sendable {
  /// The display a scripted window fills, in points, at the global origin.
  public static let display = CGRect(x: 0, y: 0, width: 1440, height: 900)

  /// The size a scripted line is drawn at, in points of `display`.
  static let fontSize: CGFloat = 20

  /// The space from one line's top to the next one's, in points of `display`.
  static let lineHeight: CGFloat = 30

  /// The space around the text, in points of `display`.
  static let margin: CGFloat = 40

  /// The app's name, as the menu bar shows it.
  public var appName: String

  /// The app's bundle identifier, which is what excludes an app.
  public var bundleID: String

  /// The front window's title.
  public var windowTitle: String?

  /// What the window shows, and what its focused text area holds.
  public var text: String

  /// Creates a scripted observation of an app's window and the text it shows.
  public init(appName: String, bundleID: String, windowTitle: String? = nil, text: String = "") {
    self.appName = appName
    self.bundleID = bundleID
    self.windowTitle = windowTitle
    self.text = text
  }

  /// The focus it describes at `date`.
  ///
  /// An excluded app is read no further than its identity, as the live tracker
  /// reads one. The pid is 0, a process no app runs as, so nothing matches it
  /// against a real app.
  func focus(at date: Date, excluded: Bool) -> FocusContext {
    var context = FocusContext(timestamp: date, pid: 0, bundleID: bundleID, appName: appName)
    if excluded {
      context.isExcluded = true
      return context
    }
    context.windowTitle = windowTitle
    context.windowFrame = Self.display
    context.focusedRole = "AXTextArea"
    context.focusedValue = String(text.prefix(FocusContext.maxValueLength))
    context.focusedValueLength = text.count
    return context
  }

  /// The lines drawn, in order: every line of `text` with its surrounding
  /// space trimmed, empty ones left out, and only as many as fit on the
  /// display.
  var lines: [(text: String, top: CGFloat)] {
    var drawn: [(String, CGFloat)] = []
    var top = Self.margin
    for line in text.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if top + Self.lineHeight > Self.display.height - Self.margin { break }
      if !trimmed.isEmpty { drawn.append((trimmed, top)) }
      top += Self.lineHeight
    }
    return drawn
  }

  /// The frame a capture of the window would give, or nil when none could be drawn.
  ///
  /// It is the size a capture of `display` is kept at for `maxDimension`: the
  /// text dark on light, and a text block for each line drawn, where it was
  /// drawn.
  func frame(maxDimension: Int) -> (image: CGImage, blocks: [TextBlock])? {
    let size = FrameImaging.boundedSize(for: Self.display.size, maxDimension: maxDimension)
    let scale = size.width / Self.display.width
    guard
      let context = CGContext(
        data: nil,
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    let font = CTFontCreateWithName("Menlo" as CFString, Self.fontSize * scale, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
        red: 0.1,
        green: 0.1,
        blue: 0.1,
        alpha: 1
      ),
    ]
    var blocks: [TextBlock] = []
    for (text, top) in lines {
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: attributes)
      )
      let width = min(
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)),
        size.width - 2 * Self.margin * scale
      )
      // Drawn with the baseline a font size under the line's top, in the
      // bottom-left coordinates CoreGraphics draws in.
      context.textPosition = CGPoint(
        x: Self.margin * scale,
        y: size.height - (top + Self.fontSize) * scale
      )
      CTLineDraw(line, context)
      let imageRect = CGRect(
        x: Self.margin * scale,
        y: top * scale,
        width: width,
        height: Self.lineHeight * scale
      )
      let screenRect = CGRect(
        x: Self.display.minX + imageRect.minX / scale,
        y: Self.display.minY + imageRect.minY / scale,
        width: imageRect.width / scale,
        height: imageRect.height / scale
      )
      blocks.append(
        TextBlock(text: text, confidence: 1, imageRect: imageRect, screenRect: screenRect)
      )
    }
    guard let image = context.makeImage() else { return nil }
    return (image, blocks)
  }
}

/// What became of a scripted observation (`SensingPipeline.observe(_:)`).
public enum ScriptedOutcome: Equatable, Sendable {
  /// It was journaled as this observation.
  case kept(ActivityObservation)

  /// A capture now would have been dropped, for this reason: a near
  /// duplicate of the frame kept last, or a mode that captures nothing, such
  /// as an excluded app in front, idle input, or a pause.
  case notKept(String)

  /// The pipeline senses the real Mac, so nothing is scripted.
  case notScripted
}
