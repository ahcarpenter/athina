import Foundation

/// A 256-bit difference hash: the image is reduced to a 17 x 16 luminance grid
/// and each bit records whether a cell is brighter than its right neighbour.
///
/// Small layout shifts and compression noise barely move it; a different window
/// or a large content change flips many bits.
public struct PerceptualHash: Equatable, Hashable, Sendable {
  /// The number of rows in the luminance grid.
  public static let gridRows = 16
  /// The number of columns in the luminance grid, one more than the bits per
  /// row since each bit compares a cell with its right neighbour.
  public static let gridColumns = 17
  /// The number of bits in the hash, 256.
  public static let bitCount = gridRows * (gridColumns - 1)

  /// Four 64-bit words, most significant bit first.
  public let words: [UInt64]

  /// Creates a hash from its four 64-bit words, most significant bit first.
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

  /// The hash as 64 lowercase hex digits, the form stored in the journal and
  /// in JSON.
  public var hexString: String {
    words.map { String(format: "%016llx", $0) }.joined()
  }

  /// Parses a hash from 64 hex digits, or returns nil for any other string.
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
  /// Decodes a hash from its 64-digit hex string, throwing on any other value.
  public init(from decoder: Decoder) throws {
    let hex = try decoder.singleValueContainer().decode(String.self)
    guard let hash = PerceptualHash(hexString: hex) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "bad hash \(hex)")
      )
    }
    self = hash
  }

  /// Encodes the hash as its 64-digit hex string.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(hexString)
  }
}
