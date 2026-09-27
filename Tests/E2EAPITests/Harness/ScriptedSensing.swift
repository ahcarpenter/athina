#if E2EAPI
  import Foundation
  import Testing

  // A hermetic run senses only what a scenario scripts through the API's `observe` (README
  // "Scripted sensing"). These script the moments the committed fixtures were recorded at, from
  // the documents in their scenario/ folder, each shown as a TextEdit window of its own.
  extension Run {
    /// The longest the toast may take to come up after the observe that brings it.
    ///
    /// It is the triage gate's 5 second floor in the seeded settings, the shortest time-based
    /// wait on the way to a toast. A toast that waited out a gate or a timer fails the check;
    /// one slowed by a loaded machine, as four scenarios at once on a CI runner slow it, does
    /// not. It comes up in about a tenth of a second.
    static let toastLatencyLimit: Duration = .seconds(5)

    /// Shows the fixtures' scenario document `name` as the TextEdit window in front, captured at
    /// once, and returns what the app did with it.
    func observeDocument(_ name: String) async throws -> Observed? {
      let file = configuration.fixtures.appendingPathComponent("scenario/\(name)")
      let text = try String(contentsOf: file, encoding: .utf8)
      return try await control.observe(
        app: "TextEdit",
        bundle: "com.apple.TextEdit",
        window: name,
        text: text
      )
    }

    /// Brings up the replay's first suggestion as the fixtures were recorded, and returns its id.
    ///
    /// First reading-notes.txt is in front, whose triage finds nothing worth a look, then a
    /// switch to cleanup-script.txt, whose triage finds something and whose mentor call makes
    /// the suggestion. The triage gate holds a second triage for its 5 second floor, which the
    /// replay clock is moved past rather than waited out. Checks that the toast comes up within
    /// `toastLatencyLimit` of the second observe.
    func scriptedToast(sourceLocation: SourceLocation = #_sourceLocation) async throws -> String {
      guard let first = try await observeDocument("reading-notes.txt") else {
        throw AppProcess.Failure("reading-notes.txt was not observed")
      }
      guard
        try await control.waitEvent("call", after: first.after, matching: ["tier": "triage"])
          != nil
      else { throw AppProcess.Failure("no triage call came after the first observation") }
      guard try await control.advance(seconds: 6).ok else {
        throw AppProcess.Failure("the replay clock would not move past the triage gate")
      }
      let started = ContinuousClock.now
      guard let second = try await observeDocument("cleanup-script.txt") else {
        throw AppProcess.Failure("cleanup-script.txt was not observed")
      }
      guard let suggestion = try await control.waitEvent("suggestion", after: second.after),
        let id = suggestion.event["id"]
      else { throw AppProcess.Failure("no suggestion came after the second observation") }
      guard try await control.waitWindow("Athina suggestion", timeout: 5) else {
        throw AppProcess.Failure("suggestion \(id) showed no toast")
      }
      let elapsed = ContinuousClock.now - started
      let seconds =
        Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
      let shown = String(format: "%.2f", seconds)
      log("toast up for suggestion \(id) \(shown)s after the second observe")
      check(
        "the toast is up within \(Self.toastLatencyLimit) of the second observe",
        true,
        elapsed <= Self.toastLatencyLimit,
        sourceLocation: sourceLocation
      )
      return id
    }

    /// A suggestion's feedback as the app's own journal holds it, `none` when it has none and
    /// `missing` when there is no such suggestion.
    func feedback(of suggestion: String) async throws -> String {
      guard
        let row = try await control.journal("suggestions").first(where: { $0["id"] == suggestion })
      else { return "missing" }
      let feedback = row["feedback"] ?? "-"
      return feedback == "-" ? "none" : feedback
    }
  }
#endif
