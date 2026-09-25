import CoreGraphics
import Foundation
import Testing

@testable import AthinaCore

@Suite struct PerceptualHashTests {
  private func grid(_ f: (Int, Int) -> UInt8) -> [UInt8] {
    var g: [UInt8] = []
    for row in 0..<PerceptualHash.gridRows {
      for col in 0..<PerceptualHash.gridColumns {
        g.append(f(col, row))
      }
    }
    return g
  }

  @Test func identicalGridsHaveZeroDistance() {
    let a = PerceptualHash(luminanceGrid: grid { col, row in UInt8((col * 13 + row * 7) % 256) })
    let b = PerceptualHash(luminanceGrid: grid { col, row in UInt8((col * 13 + row * 7) % 256) })
    #expect(a == b)
    #expect(a.distance(to: b) == 0)
  }

  @Test func horizontalGradientsSetEveryBit() {
    let rising = PerceptualHash(luminanceGrid: grid { col, _ in UInt8(col * 10) })
    let falling = PerceptualHash(luminanceGrid: grid { col, _ in UInt8(200 - col * 10) })
    #expect(rising.words.allSatisfy { $0 == 0 })
    #expect(falling.distance(to: rising) == PerceptualHash.bitCount)
  }

  @Test func smallLocalChangeMovesFewBits() {
    let base = grid { col, row in UInt8((col * 37 + row * 91) % 256) }
    var tweaked = base
    // Brighten one cell: only its two adjacent comparisons can flip.
    tweaked[5 * PerceptualHash.gridColumns + 8] = 255
    let distance = PerceptualHash(luminanceGrid: base).distance(
      to: PerceptualHash(luminanceGrid: tweaked)
    )
    #expect(distance <= 2)
  }

  @Test func hexRoundTrip() {
    let hash = PerceptualHash(
      luminanceGrid: grid { col, row in UInt8((col * 53 + row * 17) % 256) }
    )
    #expect(hash.hexString.count == 64)
    #expect(PerceptualHash(hexString: hash.hexString) == hash)
    #expect(PerceptualHash(hexString: "zz") == nil)
  }

  @Test func codableUsesHex() throws {
    let hash = PerceptualHash(words: [1, 2, 3, 0xdead_beef])
    let data = try JSONEncoder().encode(hash)
    #expect(String(decoding: data, as: UTF8.self).contains("deadbeef"))
    #expect(try JSONDecoder().decode(PerceptualHash.self, from: data) == hash)
  }

  @Test func hashesRealImagesAndDetectsChange() throws {
    let plain = try #require(TestImages.solid(width: 640, height: 400, gray: 0.5))
    let plainAgain = try #require(TestImages.solid(width: 640, height: 400, gray: 0.5))
    let split = try #require(TestImages.halves(width: 640, height: 400))
    let a = try #require(FrameImaging.perceptualHash(of: plain))
    let b = try #require(FrameImaging.perceptualHash(of: plainAgain))
    let c = try #require(FrameImaging.perceptualHash(of: split))
    #expect(a.distance(to: b) == 0)
    #expect(a.distance(to: c) >= PerceptualHash.gridRows)
  }

  @Test func boundedSizeKeepsAspect() {
    let size = FrameImaging.boundedSize(for: CGSize(width: 3456, height: 2234), maxDimension: 1280)
    #expect(size.width == 1280)
    #expect(abs(size.height - 827) <= 1)
    let small = FrameImaging.boundedSize(for: CGSize(width: 800, height: 600), maxDimension: 1280)
    #expect(small == CGSize(width: 800, height: 600))
  }

  @Test func jpegEncodes() throws {
    let image = try #require(TestImages.halves(width: 200, height: 100))
    let data = try #require(FrameImaging.jpegData(from: image, quality: 0.5))
    #expect(data.count > 100)
    #expect(data.prefix(2) == Data([0xFF, 0xD8]))
  }
}

@Suite struct FrameKeepPolicyTests {
  @Test func firstFrameIsKept() {
    #expect(
      FrameKeepPolicy.decide(distance: nil, threshold: 4, windowChanged: false, textChanged: false)
        .keep
    )
  }

  @Test func aboveThresholdIsKept() {
    #expect(
      FrameKeepPolicy.decide(distance: 5, threshold: 4, windowChanged: false, textChanged: false)
        .keep
    )
  }

  @Test func atThresholdIsDroppedWhenNothingElseChanged() {
    let verdict = FrameKeepPolicy.decide(
      distance: 4,
      threshold: 4,
      windowChanged: false,
      textChanged: false
    )
    #expect(!verdict.keep)
    #expect(verdict.distance == 4)
  }

  @Test func windowOrTextChangeOverridesNearDuplicate() {
    #expect(
      FrameKeepPolicy.decide(distance: 0, threshold: 4, windowChanged: true, textChanged: false)
        .keep
    )
    #expect(
      FrameKeepPolicy.decide(distance: 0, threshold: 4, windowChanged: false, textChanged: true)
        .keep
    )
  }
}

enum TestImages {
  static func solid(width: Int, height: Int, gray: CGFloat) -> CGImage? {
    draw(width: width, height: height) { context in
      context.setFillColor(gray: gray, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
  }

  static func halves(width: Int, height: Int) -> CGImage? {
    draw(width: width, height: height) { context in
      context.setFillColor(gray: 0.1, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
      context.setFillColor(gray: 0.9, alpha: 1)
      context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    }
  }

  private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage? {
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    body(context)
    return context.makeImage()
  }
}
