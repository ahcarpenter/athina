// Built only with the UISnapshotsSmoke trait on (Package.swift), the one way a test reaches the
// app target, so `make test` compiles none of this.
#if UISnapshotsSmoke
  import Testing

  @testable import Athina

  @Suite struct SettingsPaneTests {
    /// Every pane's own name opens that pane.
    @Test func aSavedPaneOpensItself() {
      for pane in SettingsPane.allCases {
        #expect(SettingsPane(saved: pane.rawValue) == pane)
      }
    }

    /// A pane an earlier build remembered opens the pane its settings moved to.
    @Test func aRetiredPaneOpensItsNewHome() {
      #expect(SettingsPane(saved: "contexts") == .mentoring)
      #expect(SettingsPane(saved: "capture") == .advanced)
      #expect(SettingsPane(saved: "journal") == .privacy)
      #expect(SettingsPane(saved: "nonsense") == nil)
    }
  }
#endif
