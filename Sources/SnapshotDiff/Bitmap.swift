import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image as 8-bit RGBA in sRGB, one byte per channel, rows top to bottom,
/// so two renders compare pixel for pixel whatever colour space or encoding
/// each PNG was written with.
public struct Bitmap: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// `width * height * 4` bytes: red, green, blue, alpha, premultiplied.
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4, "a bitmap holds four bytes a pixel")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A bitmap of one colour, for tests and blank canvases.
    public init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8, UInt8)) {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = fill.0
            pixels[index + 1] = fill.1
            pixels[index + 2] = fill.2
            pixels[index + 3] = fill.3
        }
        self.init(width: width, height: height, pixels: pixels)
    }

    public var size: PixelSize { PixelSize(width: width, height: height) }

    public subscript(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        get {
            let index = (y * width + x) * 4
            return (pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3])
        }
        set {
            let index = (y * width + x) * 4
            pixels[index] = newValue.0
            pixels[index + 1] = newValue.1
            pixels[index + 2] = newValue.2
            pixels[index + 3] = newValue.3
        }
    }

    /// The bitmap `factor` times smaller each way, each pixel the average of
    /// the square it replaces, as a Retina render looks at 1x.
    public func downsampled(by factor: Int) -> Bitmap {
        precondition(factor >= 1 && width % factor == 0 && height % factor == 0, "only a whole multiple downsamples")
        guard factor > 1 else { return self }
        let outWidth = width / factor, outHeight = height / factor, area = factor * factor
        var out = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        for y in 0..<outHeight {
            for x in 0..<outWidth {
                for channel in 0..<4 {
                    var sum = 0
                    for dy in 0..<factor {
                        let row = ((y * factor + dy) * width + x * factor) * 4 + channel
                        for dx in 0..<factor { sum += Int(pixels[row + dx * 4]) }
                    }
                    out[(y * outWidth + x) * 4 + channel] = UInt8((sum + area / 2) / area)
                }
            }
        }
        return Bitmap(width: outWidth, height: outHeight, pixels: out)
    }

    /// The whole factor this bitmap is larger than `size` by, the same each
    /// way, or nil when it is not a whole multiple.
    public func scaleFactor(over size: PixelSize) -> Int? {
        guard size.width > 0, size.height > 0, width % size.width == 0, height % size.height == 0 else { return nil }
        let factor = width / size.width
        return factor >= 1 && height / size.height == factor ? factor : nil
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    /// Decodes an image file, converting it to sRGB.
    public init(contentsOf url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BitmapError.unreadable(url.path)
        }
        try self.init(image)
    }

    public init(_ image: CGImage) throws {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: Bitmap.colorSpace, bitmapInfo: Bitmap.bitmapInfo
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw BitmapError.undrawable }
        self.init(width: width, height: height, pixels: pixels)
    }

    public func cgImage() throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: Bitmap.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: Bitmap.bitmapInfo),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { throw BitmapError.undrawable }
        return image
    }

    /// Writes the bitmap as a PNG.
    public func writePNG(to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw BitmapError.unwritable(url.path)
        }
        CGImageDestinationAddImage(destination, try cgImage(), nil)
        guard CGImageDestinationFinalize(destination) else { throw BitmapError.unwritable(url.path) }
    }
}

public struct PixelSize: Equatable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)x\(height)" }
}

public enum BitmapError: Error, CustomStringConvertible {
    case unreadable(String)
    case unwritable(String)
    case undrawable

    public var description: String {
        switch self {
        case .unreadable(let path): "cannot read an image at \(path)"
        case .unwritable(let path): "cannot write an image at \(path)"
        case .undrawable: "cannot make a bitmap context"
        }
    }
}
