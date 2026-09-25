import Foundation

/// A 256-bit difference hash: the image is reduced to a 17 x 16 luminance grid
/// and each bit records whether a cell is brighter than its right neighbour.
///
/// Small layout shifts and compression noise barely move it; a different window
/// or a large content change flips many bits.
public struct PerceptualHash: Equatable, Hashable, Sendable {
  public static let gridRows = 16
  public static let gridColumns = 17
  public static let bitCount = gridRows * (gridColumns - 1)

  /// Four 64-bit words, most significant bit first.
  public let words: [UInt64]

  public init(words: [UInt64]) {
    precondition(words.count == 4, "PerceptualHash needs exactly four words")
    self.words = words
  }

  /// Builds the hash from a row-major luminance grid of `gridColumns * gridRows` values.
  public init(luminanceGrid grid: [UInt8]) {
    precondition(
      grid.count == PerceptualHash.gridColumns * PerceptualHash.gridRows,
      "grid must be 17 x 16"
    )
    var words = [UInt64](repeating: 0, count: 4)
    var bitIndex = 0
    for row in 0..<PerceptualHash.gridRows {
      let base = row * PerceptualHash.gridColumns
      for col in 0..<(PerceptualHash.gridColumns - 1) {
        if grid[base + col] > grid[base + col + 1] {
          words[bitIndex / 64] |= 1 << UInt64(63 - (bitIndex % 64))
        }
        bitIndex += 1
      }
    }
    self.words = words
  }

  /// Hamming distance: number of differing bits, 0...256.
  public func distance(to other: PerceptualHash) -> Int {
    zip(words, other.words).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
  }

  public var hexString: String {
    words.map { String(format: "%016llx", $0) }.joined()
  }

  public init?(hexString: String) {
    guard hexString.count == 64 else { return nil }
    var words: [UInt64] = []
    var index = hexString.startIndex
    for _ in 0..<4 {
      let end = hexString.index(index, offsetBy: 16)
      guard let word = UInt64(hexString[index..<end], radix: 16) else { return nil }
      words.append(word)
      index = end
    }
    self.words = words
  }
}

extension PerceptualHash: Codable {
  public init(from decoder: Decoder) throws {
    let hex = try decoder.singleValueContainer().decode(String.self)
    guard let hash = PerceptualHash(hexString: hex) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "bad hash \(hex)")
      )
    }
    self = hash
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(hexString)
  }
}
