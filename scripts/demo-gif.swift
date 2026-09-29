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
// shows two crops of the same recording in turn, each at the display's own
// pixel scale: the script with its callout, then the note under the menu bar.
// Every frame is the real screen; nothing is drawn, pasted or altered, and
// time runs forward. The menu bar is left out: the real one carries whatever
// else the owner keeps there, and Athina's item reads Replay beside the Gaze
// during a replay.
//
// The moments are found in the recording itself, so no timing is carried over
// from the scenario: the switch to the script is the first change in the
// script crop and the callout its next, the note is the first change in the
// note crop, and Tell Me More is the note crop's next change after it has
// stood still. The cut list is then fixed:
//
//   the script crop   from 2 s before the switch to 2.5 s after the callout
//   the note crop     from there to 5 s after Tell Me More opens the explanation
//
// Frames are taken at 10 a second and written only when the picture changed,
// each with the time it stood, a blinking insertion point not counting as a
// change; the last is held 1.5 s more before the loop. The replay answers at
// once where a live model takes tens of seconds, so the script is held on
// screen for 2 s before the callout, which the frame before it stands for.
//
// Usage: scripts/demo-gif.swift <demo.mov> <out.gif> [--frames <dir>] [--trace]
//   --frames <dir>  also write every frame of the GIF as a PNG, to look at
//   --trace         print how much each crop changed from one frame to the
//                   next, to see why a moment was or was not found
// Exit: 0 written, 1 the recording could not be read or a moment not found,
// 2 bad usage.

// --- The recording's geometry, in points -------------------------------------

/// The width the scenario records, the display's.
let screenWidth = 1728.0
/// The menu bar, left out of every crop.
let menuBarHeight = 33.0
/// Each crop's size: wide enough for the longest line of the documents as
/// the scenario stages them, and, from the right edge, narrow enough that
/// none of the script's lines reaches into the note's crop; tall enough for
/// the note once Tell Me More has opened it.
let cropSize = CGSize(width: 864, height: 480)
/// The script and its callout, from the left edge of the screen.
let scriptCrop = CGRect(x: 0, y: menuBarHeight, width: cropSize.width, height: cropSize.height)
/// The note under the menu bar, from the right edge of the screen.
let noteCrop = CGRect(
  x: screenWidth - cropSize.width,
  y: menuBarHeight,
  width: cropSize.width,
  height: cropSize.height
)

// --- The cut list, in seconds -------------------------------------------------

let framesPerSecond = 10.0
let beforeSwitch = 2.0
let scriptBeforeCallout = 2.0
let afterCallout = 2.5
let afterExplanation = 5.0
let holdAtEnd = 1.5
/// How still the note crop stands before its next change counts as Tell Me
/// More rather than the note's own arrival.
let stillBeforeExpansion = 1.0

// --- Reading the recording ----------------------------------------------------

struct Frame {
  let time: Double
  let image: CGImage
}

func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data("demo-gif: \(message)\n".utf8))
  exit(code)
}

/// Every frame of the movie at `framesPerSecond`, as the display drew it.
func frames(of url: URL) async throws -> [Frame] {
  let asset = AVURLAsset(url: url)
  let duration = try await asset.load(.duration).seconds
  guard duration > 0 else { fail("\(url.path) holds no video") }
  let generator = AVAssetImageGenerator(asset: asset)
  generator.requestedTimeToleranceBefore = .zero
  generator.requestedTimeToleranceAfter = .zero
  var frames: [Frame] = []
  var time = 0.0
  while time < duration {
    let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
    frames.append(Frame(time: time, image: image))
    time += 1 / framesPerSecond
  }
  return frames
}

/// The pixels of `image` cropped to `rect`, given in points, as 8-bit RGBA.
struct Pixels {
  let width: Int
  let height: Int
  let bytes: [UInt8]

  init(_ image: CGImage, crop rect: CGRect, scale: CGFloat) {
    let pixelRect = CGRect(
      x: rect.minX * scale,
      y: rect.minY * scale,
      width: rect.width * scale,
      height: rect.height * scale
    )
    guard let cropped = image.cropping(to: pixelRect) else {
      fail("the recording is smaller than the crop \(rect) at scale \(scale)")
    }
    width = cropped.width
    height = cropped.height
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

  /// How many pixels differ clearly between two crops of the same size: a
  /// change of the picture rather than the video's own noise, which the
  /// threshold on each channel is well above.
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

/// A crop counts as changed when this many of its pixels differ: well above a
/// blinking insertion point (under 600 at the display's scale) and the
/// video's own noise, well below a callout, the smallest thing that appears
/// (over 6,000).
let changedPixels = 2000
/// Frames within this many pixels of the last one written are the same
/// picture: the insertion point stands still in the GIF rather than blink.
let stillPixels = 600

/// The index of the first frame after `start` whose crop differs from the
/// crop before it.
func firstChange(in crops: [Pixels], after start: Int) -> Int? {
  guard start + 1 < crops.count else { return nil }
  for index in (start + 1)..<crops.count
  where crops[index].differences(from: crops[index - 1]) >= changedPixels {
    return index
  }
  return nil
}

/// The index of the first change after the crop has stood still for
/// `stillBeforeExpansion` from `start`.
func nextChange(in crops: [Pixels], after start: Int) -> Int? {
  var index = start
  var stillSince = start
  while index + 1 < crops.count {
    index += 1
    if crops[index].differences(from: crops[index - 1]) >= changedPixels {
      if Double(index - stillSince) / framesPerSecond >= stillBeforeExpansion { return index }
      stillSince = index
    }
  }
  return nil
}

// --- Writing the GIF ------------------------------------------------------------

struct GIFFrame {
  let pixels: Pixels
  var delay: Double
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
let recording = URL(fileURLWithPath: arguments[0])
let output = URL(fileURLWithPath: arguments[1])

let semaphore = DispatchSemaphore(value: 0)
Task {
  defer { semaphore.signal() }
  let all: [Frame]
  do { all = try await frames(of: recording) } catch {
    fail("could not read \(recording.path): \(error)")
  }
  guard let first = all.first else { fail("\(recording.path) has no frames") }
  let scale = CGFloat(first.image.width) / screenWidth
  guard scale >= 1, CGFloat(first.image.height) / scale >= menuBarHeight + cropSize.height else {
    fail(
      "the recording is \(first.image.width) by \(first.image.height) pixels; the demo records the "
        + "top \(Int(menuBarHeight + cropSize.height)) points of a \(Int(screenWidth)) point wide screen"
    )
  }
  let script = all.map { Pixels($0.image, crop: scriptCrop, scale: scale) }
  let note = all.map { Pixels($0.image, crop: noteCrop, scale: scale) }
  if trace {
    for index in 1..<all.count {
      print(
        String(
          format: "%5.1f s  script %6d  note %6d",
          all[index].time,
          script[index].differences(from: script[index - 1]),
          note[index].differences(from: note[index - 1])
        )
      )
    }
  }

  guard let switched = firstChange(in: script, after: 0) else {
    fail("no switch to the script in the recording")
  }
  guard let callout = firstChange(in: script, after: switched) else {
    fail("no callout in the recording")
  }
  guard let noted = firstChange(in: note, after: switched) else { fail("no note in the recording") }
  guard let expanded = nextChange(in: note, after: noted) else {
    fail("no Tell Me More in the recording")
  }
  let seconds = { (index: Int) in String(format: "%.1f s", all[index].time) }
  print(
    "switch at \(seconds(switched)), note at \(seconds(noted)), callout at \(seconds(callout)), "
      + "Tell Me More at \(seconds(expanded))"
  )

  let frame = { (seconds: Double) in Int((seconds * framesPerSecond).rounded()) }
  let start = max(0, switched - frame(beforeSwitch))
  let cut = min(all.count - 1, callout + frame(afterCallout))
  let end = min(all.count - 1, expanded + frame(afterExplanation))
  guard noted < cut, cut < expanded else {
    fail("the note, the callout and Tell Me More are too close together for the cut")
  }

  var gif: [GIFFrame] = []
  let sequence = (start..<cut).map { script[$0] } + (cut...end).map { note[$0] }
  for (offset, pixels) in sequence.enumerated() {
    if let last = gif.last, last.pixels.differences(from: pixels) < stillPixels {
      gif[gif.count - 1].delay += 1 / framesPerSecond
    } else {
      if start + offset == callout {
        let shown = Double(callout - switched) / framesPerSecond
        if shown < scriptBeforeCallout { gif[gif.count - 1].delay += scriptBeforeCallout - shown }
      }
      gif.append(GIFFrame(pixels: pixels, delay: 1 / framesPerSecond))
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
semaphore.wait()
