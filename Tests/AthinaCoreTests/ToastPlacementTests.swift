import CoreGraphics
import Testing

@testable import AthinaCore

@Suite struct ToastPlacementTests {
  /// A 1728 by 1117 display less a 33 point menu bar, in AppKit's space.
  let visible = CGRect(x: 0, y: 0, width: 1728, height: 1084)

  @Test func aToastOpensAtTheTopRightUnderTheMenuBar() {
    let frame = ToastPlacement.frame(
      size: CGSize(width: 382, height: 180),
      visible: visible,
      margin: 12,
      movedTopLeft: nil
    )
    #expect(frame == CGRect(x: 1728 - 382 - 12, y: 1084 - 180 - 12, width: 382, height: 180))
  }

  /// Dragged aside, it keeps its top edge and place as it grows, rather than
  /// jumping back over what it was moved off.
  @Test func aDraggedToastGrowsDownwardWhereItWasPut() {
    let moved = CGPoint(x: 200, y: 900)
    let small = ToastPlacement.frame(
      size: CGSize(width: 382, height: 180),
      visible: visible,
      margin: 12,
      movedTopLeft: moved
    )
    let grown = ToastPlacement.frame(
      size: CGSize(width: 382, height: 460),
      visible: visible,
      margin: 12,
      movedTopLeft: moved
    )
    #expect(small.minX == 200 && small.maxY == 900)
    #expect(grown.minX == 200 && grown.maxY == 900 && grown.height == 460)
  }

  @Test func aDraggedToastStaysWholeOnTheScreen() {
    let low = ToastPlacement.frame(
      size: CGSize(width: 382, height: 460),
      visible: visible,
      margin: 12,
      movedTopLeft: CGPoint(x: 1600, y: 200)
    )
    #expect(low.minY == 0 && low.maxY == 460)
    #expect(low.maxX == 1728)
    let high = ToastPlacement.frame(
      size: CGSize(width: 382, height: 180),
      visible: visible,
      margin: 12,
      movedTopLeft: CGPoint(x: -50, y: 2000)
    )
    #expect(high.minX == 0 && high.maxY == 1084)
  }

  @Test func aNoteStaysLongEnoughToRead() {
    #expect(ToastPlacement.noteDuration(for: "Nothing to reply to yet.") == 4)
    let instruction = """
      Athina needs Microphone and Speech Recognition to hear you. Answer the system's request, \
      then hold the shortcut again.
      """
    // 18 words at 3 a second.
    #expect(ToastPlacement.noteDuration(for: instruction) == 6)
  }
}
