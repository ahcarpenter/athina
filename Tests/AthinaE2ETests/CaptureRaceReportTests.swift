import Foundation
import Testing

@testable import AthinaE2E

@Suite struct CaptureRaceReportTests {
  private let start = Date(timeIntervalSince1970: 1_000_000)

  private func change(_ id: Int, _ offset: TimeInterval) -> CaptureRaceReport.Switch {
    CaptureRaceReport.Switch(id: id, at: start + offset, kind: "windowSwitch")
  }

  private func capture(
    _ id: Int,
    _ offset: TimeInterval,
    _ reason: String
  ) -> CaptureRaceReport.Capture {
    CaptureRaceReport.Capture(id: id, at: start + offset, reason: reason)
  }

  @Test func aFocusChangeCaptureAfterASwitchKeepsIt() {
    let report = CaptureRaceReport.evaluate(
      switches: [change(1, 10)],
      captures: [capture(1, 5, "floor"), capture(2, 12, "focusChange")]
    )
    #expect(report.moments.count == 1)
    #expect(report.moments[0].verdict == "kept")
    #expect(report.moments[0].captureID == 2)
    #expect(report.kept == 1)
    #expect(report.dropped == 0)
  }

  @Test func aCaptureForAnotherReasonMeansTheSwitchWasDropped() {
    // The race: the switch landed while a capture was in flight, that
    // capture cleared it, and the next capture came from the floor cadence.
    let report = CaptureRaceReport.evaluate(
      switches: [change(1, 10)],
      captures: [capture(1, 12, "floor")]
    )
    #expect(report.moments[0].verdict == "dropped")
    #expect(report.moments[0].captureReason == "floor")
    #expect(report.dropped == 1)
  }

  @Test func switchesWithNoCaptureBetweenThemAreOneChangeMoment() {
    let report = CaptureRaceReport.evaluate(
      switches: [change(1, 10), change(2, 11), change(3, 12)],
      captures: [capture(1, 20, "focusChange")]
    )
    #expect(report.moments.count == 1)
    #expect(report.moments[0].switchIDs == [1, 2, 3])
    #expect(report.moments[0].verdict == "kept")
  }

  @Test func aCaptureBetweenSwitchesStartsANewMoment() {
    let report = CaptureRaceReport.evaluate(
      switches: [change(1, 10), change(2, 30)],
      captures: [capture(1, 20, "focusChange"), capture(2, 40, "inputSettled")]
    )
    #expect(report.moments.count == 2)
    #expect(report.moments[0].verdict == "kept")
    #expect(report.moments[1].verdict == "dropped")
    #expect(report.kept == 1)
    #expect(report.dropped == 1)
  }

  @Test func aSwitchWithNoCaptureAfterItIsPendingNotDropped() {
    let report = CaptureRaceReport.evaluate(
      switches: [change(1, 10)],
      captures: [capture(1, 5, "floor")]
    )
    #expect(report.moments[0].verdict == "pending")
    #expect(report.pending == 1)
    #expect(report.dropped == 0)
  }

  @Test func rowsOutOfOrderAreSortedBeforeJudging() {
    let report = CaptureRaceReport.evaluate(
      switches: [change(2, 30), change(1, 10)],
      captures: [capture(2, 40, "focusChange"), capture(1, 20, "focusChange")]
    )
    #expect(report.moments.map(\.switchIDs) == [[1], [2]])
    #expect(report.kept == 2)
  }

  @Test func noSwitchesMeansNoMoments() {
    let report = CaptureRaceReport.evaluate(switches: [], captures: [capture(1, 5, "floor")])
    #expect(report.moments.isEmpty)
    #expect(report.kept == 0)
  }
}
