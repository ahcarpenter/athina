import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// CoreGraphics helpers for captured frames.
public enum FrameImaging {
  /// Downsamples the image to the hash grid using area-averaging interpolation.
  public static func luminanceGrid(of image: CGImage) -> [UInt8]? {
    let width = PerceptualHash.gridColumns
    let height = PerceptualHash.gridRows
    var pixels = [UInt8](repeating: 0, count: width * height)
    let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width,
          space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
      else { return false }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    return ok ? pixels : nil
  }

  public static func perceptualHash(of image: CGImage) -> PerceptualHash? {
    luminanceGrid(of: image).map(PerceptualHash.init(luminanceGrid:))
  }

  /// Encodes a JPEG with the given quality (0...1).
  public static func jpegData(from image: CGImage, quality: Double) -> Data? {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else {
      return nil
    }
    let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }

  /// The size a `sourceSize` frame is captured at so its longest edge is at most `maxDimension`.
  public static func boundedSize(for sourceSize: CGSize, maxDimension: Int) -> CGSize {
    let longest = max(sourceSize.width, sourceSize.height)
    guard longest > 0 else { return sourceSize }
    let scale = min(1, CGFloat(maxDimension) / longest)
    return CGSize(
      width: max(1, (sourceSize.width * scale).rounded(.down)),
      height: max(1, (sourceSize.height * scale).rounded(.down))
    )
  }
}
