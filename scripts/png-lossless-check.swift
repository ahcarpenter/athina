// Proves a recompression of PNGs was lossless: decodes every PNG under
// <before> and the file at the same relative path under <after>, each to 8-bit
// sRGB RGBA without premultiplying, so a transparent pixel's colour counts too,
// and fails unless every pixel of every pair is the same and each pair has the
// same bit depth and colour type, since swift-snapshot-testing cannot load a
// reference reduced to a palette or to grey. Prints each pair that differs or
// is missing, then the files compared and the bytes saved.
//
// Usage: swift scripts/png-lossless-check.swift <before> <after>
// Exit: 0 every pair is the same pixels in the same format, 1 any is not,
// 2 bad usage.

import Accelerate
import CoreGraphics
import Foundation
import ImageIO

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
  FileHandle.standardError.write(
    "usage: swift scripts/png-lossless-check.swift <before> <after>\n".data(using: .utf8)!
  )
  exit(2)
}
let before = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let after = URL(fileURLWithPath: arguments[2]).standardizedFileURL

/// The image at `url` as width, height and its RGBA bytes, unpremultiplied.
func rgba(_ url: URL) -> (Int, Int, [UInt8])? {
  guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
    let format = vImage_CGImageFormat(
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
    ),
    var buffer = try? vImage_Buffer(cgImage: image, format: format)
  else { return nil }
  defer { buffer.free() }
  let rowLength = image.width * 4
  var pixels = [UInt8](repeating: 0, count: rowLength * image.height)
  pixels.withUnsafeMutableBytes { target in
    for row in 0..<image.height {
      memcpy(target.baseAddress! + row * rowLength, buffer.data + row * buffer.rowBytes, rowLength)
    }
  }
  return (image.width, image.height, pixels)
}

/// The PNG's bit depth and colour type, from its header, or nil when it is not a PNG.
func format(_ url: URL) -> [UInt8]? {
  guard let data = try? Data(contentsOf: url), data.count > 25,
    data[12..<16].elementsEqual("IHDR".utf8)
  else { return nil }
  return [data[24], data[25]]
}

func size(_ url: URL) -> Int {
  (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
}

var compared = 0
var failed = 0
var bytesBefore = 0
var bytesAfter = 0
let files = FileManager.default.enumerator(at: before, includingPropertiesForKeys: nil)!
for case let file as URL in files where file.pathExtension == "png" {
  let relative = String(file.standardizedFileURL.path.dropFirst(before.path.count + 1))
  let other = after.appendingPathComponent(relative)
  compared += 1
  guard let old = rgba(file) else {
    print("unreadable: \(arguments[1])/\(relative)")
    failed += 1
    continue
  }
  guard let new = rgba(other) else {
    print("missing or unreadable: \(arguments[2])/\(relative)")
    failed += 1
    continue
  }
  bytesBefore += size(file)
  bytesAfter += size(other)
  if old.0 != new.0 || old.1 != new.1 || old.2 != new.2 {
    print("pixels differ: \(relative)")
    failed += 1
  } else if let was = format(file), let now = format(other), was != now {
    print("format changed: \(relative), bit depth and colour type \(was) became \(now)")
    failed += 1
  }
}

let saved = bytesBefore - bytesAfter
let percent = bytesBefore == 0 ? 0 : Double(saved) * 100 / Double(bytesBefore)
if failed == 0 {
  print(
    "png-lossless-check: all \(compared) PNGs are the same RGBA pixels in the same format; "
      + "\(bytesBefore) bytes before, \(bytesAfter) after, \(saved) saved "
      + "(\(String(format: "%.1f", percent))%)"
  )
  exit(0)
}
print(
  "png-lossless-check: \(failed) of \(compared) PNGs differ, changed format or could not be read"
)
exit(1)
