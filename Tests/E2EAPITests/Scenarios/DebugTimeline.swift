#if E2EAPI
  import Foundation
  import Testing

  extension Scenarios {
    /// The debug panel's Timeline shows each startup row once.
    ///
    /// A timeline that read the journal back after sensing had journaled its first events,
    /// Started among them, while the live stream carried the same rows, showed every startup row
    /// twice. AppState loads the timeline before pipeline.start(), so the startup rows arrive on
    /// the stream alone, and the timeline merges rows by journal id for any later load that
    /// overlaps the stream, such as the reload after Clear Journal, and for ids the journal
    /// reuses. The panel is open from launch here, which is where a person saw it. The Timeline
    /// is read through Athina's own accessibility tree, and the journal through the app's named
    /// queries. The run scripts no sensing, so it senses nothing: Started is the startup row
    /// counted, and the rows of an app switch or capture are not there to be.
    @Test func `debug-timeline`() async {
      await Run.scenario("debug-timeline", arguments: ["--open", "debug"]) { run in
        let control = run.control
        // Every row the Timeline can show: observations and events together.
        let journalRows = {
          let counts = try await control.journal("counts").first ?? [:]
          return (Int(counts["observations"] ?? "") ?? 0) + (Int(counts["events"] ?? "") ?? 0)
        }
        // Started events with no detail, the rows the Timeline shows as the label alone.
        let startedRows = {
          try await control.journal("events").filter {
            $0["kind"] == "started" && $0["detail"] == "-"
          }
          .count
        }
        // The count the Timeline's header shows, "7 entries", as a number.
        let headerCount = {
          let value =
            try await control.first(.identifier("debugPanel.sideCount", in: "Debug Panel"))?.value
            ?? ""
          return Int(value.prefix { $0.isNumber })
        }

        guard try await control.waitWindow("Debug Panel", timeout: 20) else {
          throw AppProcess.Failure("the debug panel never opened")
        }
        for _ in 0..<50 {
          if try await startedRows() > 0 { break }
          try await Task.sleep(for: .milliseconds(100))
        }
        // The journal can still gain a row, so the header is compared with a journal that held
        // still across the read; a row can reach the panel a moment after the journal, so a few
        // reads are allowed before the two are compared.
        var shown: Int?
        var after = 0
        var rows: [Element] = []
        for _ in 0..<10 {
          let before = try await journalRows()
          shown = try await headerCount()
          rows = try await control.find(.identifier("debugPanel.timelineRow", in: "Debug Panel"))
          after = try await journalRows()
          if before == after, shown == after { break }
          try await Task.sleep(for: .milliseconds(500))
        }
        try await run.picture("Debug Panel", "timeline")
        guard let shown else {
          throw AppProcess.Failure("the Debug Panel showed no Timeline header to read")
        }
        // No Started row would match no row of it, so a launch that journaled none is a scenario
        // failure rather than a check that passes by saying nothing.
        let started = try await startedRows()
        guard started >= 1 else {
          throw AppProcess.Failure("the launch journaled no Started row to count")
        }

        run.check("the Timeline lists each journaled row once", after, shown)
        // Rows whose text is the label alone, at any time of day: "12:00:00, Started".
        let listed = rows.filter { row in
          [row.value, row.label].contains { $0.wholeMatch(of: /[0-9:]+, Started/) != nil }
        }
        run.check("Started is listed once for each launch journaled", started, listed.count)
      }
    }
  }
#endif
