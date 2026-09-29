#!/usr/bin/env swift
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Cuts the README's demo GIF from the recording the `demo` end-to-end scenario
// makes (scripts/e2e/scenarios/demo.sh): the top of the real screen, 1728
// points wide, while the committed fixtures replay. A frame that held both the
// script at the left and the note at the top right would be the whole width of
// the display, unreadable at the 800 pixels GitHub shows it at, so the GIF
// follows the screen with a camera: a frame half the display's width, at the
// display's own pixel scale, that pulls back to the whole width for the moment
// the note and the callout arrive together, then closes in on the callout,
// pans across to the note, and stays for Tell Me More. Every frame is the
// real screen, cropped or scaled down and never drawn on, and time runs
// forward. The menu bar is left out: the real one carries whatever else the
// owner keeps there, and Athina's item reads Replay beside the Gaze during a
// replay.
//
// The moments are found in the recording itself, so no timing is carried over
// from the scenario: the switch to the script is the first change at the left
// of the screen and the callout its next, the note is the first change at the
// top right, and Tell Me More is the next change there after the note has
// stood still. The shots are then fixed (`shots`), each a camera frame or a
// move between two, showing either a moment of the recording as it happened
// or one instant of it: the screen stands still between the switch and the
// answer, and again while the note is read, so those instants are where the
// camera moves and where the GIF holds. Frames are taken 15 times a second
// through everything that moves, on the screen or in the camera, and one
// frame stands for a still with the time it stood; the last is held before
// the loop.
//
// Usage: scripts/demo-gif.swift <demo.mov> <out.gif> [--frames <dir>] [--trace]
//   --frames <dir>  also write every frame of the GIF as a PNG, to look at
//   --trace         print how much each region changed from one frame to the
//                   next, to see why a moment was or was not found
// Exit: 0 written, 1 the recording could not be read or a moment not found,
// 2 bad usage.

// --- The recording's geometry, in points -------------------------------------

/// The width the scenario records, the display's.
let screenWidth = 1728.0
/// Where every frame's top edge is, 8 points under the menu bar.
///
/// The menu bar is left out, and the top edge sits just above the window's
/// traffic lights. The window's rounded top right corner shows the desktop
/// through it, and the note's own rounded corner leaves that spot uncovered;
/// with the top here, and the note's frame ending 6 points right of the
/// note, it is out of the picture.
let frameTop = 41.0
/// The note's right edge is 12 points from the display's; its frame ends 6
/// points right of it.
let noteRightMargin = 6.0
/// The camera's frame when it is close: wide enough for the longest line of
/// the documents as the scenario stages them, tall enough for the note once
/// Tell Me More has opened it, and half the display's width, so the whole
/// width is the same frame at half scale.
let closeSize = CGSize(width: 864, height: 480)
/// The script and its callout, from the left edge of the screen.
let scriptView = CGRect(origin: CGPoint(x: 0, y: frameTop), size: closeSize)
/// The note under the menu bar, at the right edge of the screen.
let noteView = CGRect(
  origin: CGPoint(x: screenWidth - 12 - noteRightMargin - closeSize.width, y: frameTop),
  size: closeSize
)
/// The whole width up to the note's frame's right edge, where the note and
/// the callout arrive together, at just under half scale.
let wideView = CGRect(
  x: 0,
  y: frameTop,
  width: noteView.maxX,
  height: noteView.maxX * closeSize.height / closeSize.width
)

// --- The cut -----------------------------------------------------------------

let framesPerSecond = 15.0
/// How long a camera move takes.
let moveSeconds = 0.8
/// How long the last frame stays before the loop.
let holdAtEnd = 1.5
/// How still the top right stands before its next change counts as Tell Me
/// More rather than the note's own arrival.
let stillBeforeExpansion = 1.0

/// One shot: the camera goes from one frame to another (the same for a
/// camera that stands) over `seconds`, showing the recording from `at` on as
/// it happened (`live`) or the one instant `at` throughout.
struct Shot {
  let from: CGRect
  let to: CGRect
  let seconds: Double
  let at: Double
  let live: Bool

  static func still(_ view: CGRect, at: Double, for seconds: Double) -> Shot {
    Shot(from: view, to: view, seconds: seconds, at: at, live: false)
  }

  static func live(_ view: CGRect, from at: Double, for seconds: Double) -> Shot {
    Shot(from: view, to: view, seconds: seconds, at: at, live: true)
  }

  static func move(_ from: CGRect, to: CGRect, at: Double) -> Shot {
    Shot(from: from, to: to, seconds: moveSeconds, at: at, live: false)
  }
}

/// The shots, from the moments found in the recording, in seconds of it.
func shots(switched: Double, noted: Double, callout: Double, expanded: Double) -> [Shot] {
  let arrived = max(noted, callout)
  return [
    // The notes, then the switch to the script, as they happened.
    .live(scriptView, from: switched - 2.0, for: 2.3),
    // The script stands until the answer: the camera pulls back over it.
    .still(scriptView, at: switched + 0.3, for: 1.0),
    .move(scriptView, to: wideView, at: switched + 0.3),
    .still(wideView, at: switched + 0.3, for: 0.4),
    // The note and the callout arrive, and stand.
    .live(wideView, from: noted - 0.2, for: arrived - noted + 1.4),
    // In on the callout, then across to the note.
    .move(wideView, to: scriptView, at: arrived + 1.2),
    .still(scriptView, at: arrived + 1.2, for: 2.0),
    .move(scriptView, to: noteView, at: arrived + 1.2),
    .still(noteView, at: arrived + 1.2, for: 2.0),
    // Tell Me More opens the explanation, which stays.
    .live(noteView, from: expanded - 0.2, for: 4.2),
  ]
}

// --- Reading the recording ----------------------------------------------------

func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data("demo-gif: \(message)\n".utf8))
  exit(code)
}

/// The recording, read a frame at a time.
final class Recording {
  let generator: AVAssetImageGenerator
  let duration: Double
  /// Pixels per point.
  let scale: CGFloat
  let width: Int
  let height: Int

  init(_ url: URL) async throws {
    let asset = AVURLAsset(url: url)
    duration = try await asset.load(.duration).seconds
    guard duration > 0, let track = try await asset.loadTracks(withMediaType: .video).first
    else { fail("\(url.path) holds no video") }
    let size = try await track.load(.naturalSize)
    width = Int(size.width)
    height = Int(size.height)
    scale = size.width / screenWidth
    generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
  }

  /// The frame the display showed at `seconds`, or the nearest one inside
  /// the recording.
  func frame(at seconds: Double) async throws -> CGImage {
    let time = min(max(seconds, 0), duration - 1 / framesPerSecond)
    return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
  }
}

/// A frame of the GIF: the recording seen through the camera, as 8-bit RGB.
struct Pixels {
  static let canvas = CGSize(width: closeSize.width * 2, height: closeSize.height * 2)
  let width = Int(Pixels.canvas.width)
  let height = Int(Pixels.canvas.height)
  let bytes: [UInt8]

  /// `image` cropped to `view`, given in points, and scaled to the canvas.
  init(_ image: CGImage, view: CGRect, scale: CGFloat) {
    let pixelRect = CGRect(
      x: (view.minX * scale).rounded(),
      y: (view.minY * scale).rounded(),
      width: (view.width * scale).rounded(),
      height: (view.height * scale).rounded()
    )
    guard let cropped = image.cropping(to: pixelRect) else {
      fail("the recording is smaller than the camera's frame \(view) at scale \(scale)")
    }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
      data: &bytes,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.interpolationQuality = .high
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
    self.bytes = bytes
  }

  /// The image of these pixels, opaque.
  var image: CGImage {
    let data = CFDataCreate(nil, bytes, bytes.count)!
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: CGDataProvider(data: data)!,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )!
  }

  /// How many pixels differ clearly from another frame: a change of the
  /// picture rather than the video's own noise, which the threshold on each
  /// channel is well above.
  func differences(from other: Pixels) -> Int {
    var count = 0
    var index = 0
    while index < bytes.count {
      if abs(Int(bytes[index]) - Int(other.bytes[index])) > 40
        || abs(Int(bytes[index + 1]) - Int(other.bytes[index + 1])) > 40
        || abs(Int(bytes[index + 2]) - Int(other.bytes[index + 2])) > 40
      {
        count += 1
      }
      index += 4
    }
    return count
  }
}

// --- Finding the moments --------------------------------------------------------

/// A region counts as changed when this many of its pixels differ: well above
/// a blinking insertion point (under 600 at the display's scale) and the
/// video's own noise, well below a callout, the smallest thing that appears
/// (over 6,000).
let changedPixels = 2000
/// Frames within this many pixels of the last one written are the same
/// picture: the insertion point stands still in the GIF rather than blink.
let stillPixels = 600
/// How often the recording is looked at for its moments.
let lookEvery = 0.1

/// How much the script's and the note's regions changed from each frame to
/// the one before, through the recording.
func changes(in recording: Recording) async throws -> (times: [Double], script: [Int], note: [Int])
{
  var times: [Double] = []
  var script: [Int] = []
  var note: [Int] = []
  var previous: (script: Pixels, note: Pixels)?
  var time = 0.0
  while time < recording.duration {
    let image = try await recording.frame(at: time)
    let current = (
      script: Pixels(image, view: scriptView, scale: recording.scale),
      note: Pixels(image, view: noteView, scale: recording.scale)
    )
    times.append(time)
    script.append(previous.map { current.script.differences(from: $0.script) } ?? 0)
    note.append(previous.map { current.note.differences(from: $0.note) } ?? 0)
    previous = current
    time += lookEvery
  }
  return (times, script, note)
}

/// The index of the first change after `start`.
func firstChange(in changes: [Int], after start: Int) -> Int? {
  guard start + 1 < changes.count else { return nil }
  return ((start + 1)..<changes.count).first { changes[$0] >= changedPixels }
}

/// The index of the first change after the region has stood still for
/// `stillBeforeExpansion` from `start`.
func nextChange(in changes: [Int], after start: Int) -> Int? {
  var stillSince = start
  for index in (start + 1)..<changes.count where changes[index] >= changedPixels {
    if Double(index - stillSince) * lookEvery >= stillBeforeExpansion { return index }
    stillSince = index
  }
  return nil
}

// --- Writing the GIF ------------------------------------------------------------

struct GIFFrame {
  let pixels: Pixels
  var delay: Double
}

/// A camera frame part way from one to another, eased in and out.
func between(_ from: CGRect, _ to: CGRect, _ fraction: Double) -> CGRect {
  let eased = fraction * fraction * (3 - 2 * fraction)
  func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
  return CGRect(
    x: mix(from.minX, to.minX),
    y: mix(from.minY, to.minY),
    width: mix(from.width, to.width),
    height: mix(from.height, to.height)
  )
}

func writeGIF(_ frames: [GIFFrame], to url: URL) {
  guard
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL,
      UTType.gif.identifier as CFString,
      frames.count,
      nil
    )
  else { fail("could not write \(url.path)") }
  CGImageDestinationSetProperties(
    destination,
    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
  )
  for frame in frames {
    CGImageDestinationAddImage(
      destination,
      frame.pixels.image,
      [
        kCGImagePropertyGIFDictionary: [
          kCGImagePropertyGIFDelayTime: frame.delay,
          kCGImagePropertyGIFUnclampedDelayTime: frame.delay,
        ]
      ] as CFDictionary
    )
  }
  guard CGImageDestinationFinalize(destination) else { fail("could not finish \(url.path)") }
}

func writePNG(_ pixels: Pixels, to url: URL) {
  guard
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL,
      UTType.png.identifier as CFString,
      1,
      nil
    )
  else { fail("could not write \(url.path)") }
  CGImageDestinationAddImage(destination, pixels.image, nil)
  guard CGImageDestinationFinalize(destination) else { fail("could not finish \(url.path)") }
}

// --- Main -----------------------------------------------------------------------

var arguments = Array(CommandLine.arguments.dropFirst())
var framesDirectory: URL?
let trace = arguments.contains("--trace")
arguments.removeAll { $0 == "--trace" }
if let flag = arguments.firstIndex(of: "--frames") {
  guard flag + 1 < arguments.count else { fail("--frames takes a directory", code: 2) }
  framesDirectory = URL(fileURLWithPath: arguments[flag + 1])
  arguments.removeSubrange(flag...(flag + 1))
}
guard arguments.count == 2 else {
  fail("usage: scripts/demo-gif.swift <demo.mov> <out.gif> [--frames <dir>] [--trace]", code: 2)
}
let recordingURL = URL(fileURLWithPath: arguments[0])
let output = URL(fileURLWithPath: arguments[1])

let semaphore = DispatchSemaphore(value: 0)
Task {
  defer { semaphore.signal() }
  do { try await cut() } catch { fail("could not read \(recordingURL.path): \(error)") }
}
semaphore.wait()

func cut() async throws {
  let recording = try await Recording(recordingURL)
  guard recording.scale >= 1, CGFloat(recording.height) / recording.scale >= wideView.maxY
  else {
    fail(
      "the recording is \(recording.width) by \(recording.height) pixels; the demo records the "
        + "top \(Int(wideView.maxY)) points of a \(Int(screenWidth)) point wide screen"
    )
  }
  let changed = try await changes(in: recording)
  if trace {
    for index in changed.times.indices {
      print(
        String(
          format: "%5.1f s  script %6d  note %6d",
          changed.times[index],
          changed.script[index],
          changed.note[index]
        )
      )
    }
  }
  guard let switched = firstChange(in: changed.script, after: 0) else {
    fail("no switch to the script in the recording")
  }
  guard let callout = firstChange(in: changed.script, after: switched) else {
    fail("no callout in the recording")
  }
  guard let noted = firstChange(in: changed.note, after: switched) else {
    fail("no note in the recording")
  }
  guard let expanded = nextChange(in: changed.note, after: noted) else {
    fail("no Tell Me More in the recording")
  }
  let time = { (index: Int) in changed.times[index] }
  print(
    String(
      format: "switch at %.1f s, note at %.1f s, callout at %.1f s, Tell Me More at %.1f s",
      time(switched),
      time(noted),
      time(callout),
      time(expanded)
    )
  )
  guard time(noted) - time(switched) >= 0.3,
    time(expanded) - max(time(noted), time(callout)) >= 1.4
  else { fail("the switch, the note and Tell Me More are too close together for the cut") }

  // The frames, one for each tick of the camera, the same picture standing
  // as one frame; the recording is read once for each new instant.
  var gif: [GIFFrame] = []
  var lastInstant = -1.0
  var lastImage: CGImage?
  func frame(at instant: Double) async throws -> CGImage {
    if let lastImage, instant == lastInstant { return lastImage }
    let image = try await recording.frame(at: instant)
    lastInstant = instant
    lastImage = image
    return image
  }
  let cut = shots(
    switched: time(switched),
    noted: time(noted),
    callout: time(callout),
    expanded: time(expanded)
  )
  for shot in cut {
    let ticks = Int((shot.seconds * framesPerSecond).rounded())
    for tick in 0..<ticks {
      let elapsed = Double(tick) / framesPerSecond
      let instant = shot.live ? shot.at + elapsed : shot.at
      let view =
        ticks > 1 ? between(shot.from, shot.to, Double(tick) / Double(ticks - 1)) : shot.to
      let pixels = Pixels(try await frame(at: instant), view: view, scale: recording.scale)
      if let last = gif.last, last.pixels.differences(from: pixels) < stillPixels {
        gif[gif.count - 1].delay += 1 / framesPerSecond
      } else {
        gif.append(GIFFrame(pixels: pixels, delay: 1 / framesPerSecond))
      }
    }
  }
  gif[gif.count - 1].delay += holdAtEnd

  if let framesDirectory {
    try? FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
    for (index, frame) in gif.enumerated() {
      writePNG(
        frame.pixels,
        to: framesDirectory.appendingPathComponent(String(format: "%03d.png", index))
      )
    }
  }
  writeGIF(gif, to: output)
  let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
  let length = gif.reduce(0) { $0 + $1.delay }
  print(
    "\(output.path): \(gif.count) frames, \(String(format: "%.1f", length)) s, "
      + "\(gif[0].pixels.width) by \(gif[0].pixels.height) pixels, \(size / 1024) KB"
  )
}
