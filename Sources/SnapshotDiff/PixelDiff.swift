/// How two bitmaps of one size differ.
///
/// A pixel counts as changed when any of its four channels moved by more than
/// the tolerance, so a tolerance covers the faint shading a glyph or curve's
/// anti-aliased edge can pick up, and nothing a person would see: a shifted
/// edge, a new colour or a moved line moves some channel much further.
public struct PixelDiff: Equatable, Sendable {
    /// Pixels whose largest channel difference is above the tolerance.
    public let changedPixels: Int
    /// The largest channel difference anywhere, tolerated or not.
    public let largestDelta: Int
    /// The smallest rectangle holding every changed pixel, in pixels from the
    /// top left, or nil when none changed.
    public let changedBounds: PixelRect?

    public var matches: Bool { changedPixels == 0 }

    /// Compares two bitmaps of the same size.
    public static func compare(_ before: Bitmap, _ after: Bitmap, tolerance: Int) -> PixelDiff {
        precondition(before.size == after.size, "only bitmaps of one size compare pixel for pixel")
        var changed = 0
        var largest = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        before.pixels.withUnsafeBufferPointer { a in
            after.pixels.withUnsafeBufferPointer { b in
                for pixel in 0..<(before.width * before.height) {
                    let index = pixel * 4
                    var delta = 0
                    for channel in 0..<4 {
                        delta = max(delta, abs(Int(a[index + channel]) - Int(b[index + channel])))
                    }
                    largest = max(largest, delta)
                    if delta > tolerance {
                        changed += 1
                        let x = pixel % before.width, y = pixel / before.width
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
        }
        let bounds = changed == 0 ? nil : PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return PixelDiff(changedPixels: changed, largestDelta: largest, changedBounds: bounds)
    }

    /// The after image washed out to a pale grey, with every changed pixel in
    /// solid red, so where it changed reads at a glance at the image's own size.
    public static func highlight(_ before: Bitmap, _ after: Bitmap, tolerance: Int) -> Bitmap {
        precondition(before.size == after.size, "only bitmaps of one size compare pixel for pixel")
        var out = after
        out.pixels.withUnsafeMutableBufferPointer { o in
            before.pixels.withUnsafeBufferPointer { a in
                for index in stride(from: 0, to: o.count, by: 4) {
                    var delta = 0
                    for channel in 0..<4 {
                        delta = max(delta, abs(Int(a[index + channel]) - Int(o[index + channel])))
                    }
                    if delta > tolerance {
                        o[index] = 255; o[index + 1] = 0; o[index + 2] = 0; o[index + 3] = 255
                    } else {
                        // Luminance over white, faded to a quarter of its contrast.
                        let luminance = (Int(o[index]) * 299 + Int(o[index + 1]) * 587 + Int(o[index + 2]) * 114) / 1000
                        let composited = min(255, luminance + (255 - Int(o[index + 3])))
                        let pale = UInt8(255 - (255 - composited) / 4)
                        o[index] = pale; o[index + 1] = pale; o[index + 2] = pale; o[index + 3] = 255
                    }
                }
            }
        }
        return out
    }
}

public struct PixelRect: Equatable, Sendable, CustomStringConvertible {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)x\(height) at \(x),\(y)" }
}
