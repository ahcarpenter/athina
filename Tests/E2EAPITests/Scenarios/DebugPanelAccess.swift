#if E2EAPI
  import AthinaControlProtocol
  import Foundation
  import Testing

  extension Scenarios {
    /// The debug panel opens from Settings > Advanced and the menu's Debug Panel command only
    /// once it is enabled, and closes when it is turned off.
    ///
    /// While Settings > Advanced > Enable debug panel is off, as every install starts, the menu
    /// offers no command for it and the pane's Open Debug Panel button is dimmed; turned on, the
    /// menu gains a Debug Panel command in a group of its own after Settings…, as Safari's
    /// Advanced switch adds its Develop menu, and that command and the button both open the
    /// panel; turned off again, the panel goes and so does the command, with no relaunch. Every
    /// click is simulated inside Athina, through AppKit's own event path, on the control its own
    /// accessibility tree names, so a click that lands proves the control is hit-testable and
    /// wired; a click on the dimmed button is refused, and one forced onto it does nothing. The
    /// menu is read and its command chosen through the menu's own action; that macOS draws and
    /// opens it is the real-screen tier's to prove.
    @Test func `debug-panel-access`() async {
      await Run.scenario("debug-panel-access", arguments: ["--open", "settings:advanced"]) { run in
        let control = run.control
        let toggle = Target.identifier("advanced.enableDebugPanel", in: "Advanced")
        let button = Target.identifier("advanced.openDebugPanel", in: "Advanced")
        let switchValue = { try await control.first(toggle)?.value ?? "" }
        let buttonEnabled = { try await control.first(button)?.enabled }
        let panelOpen = { (timeout: Double) in
          try await control.waitWindow("Debug Panel", timeout: timeout)
        }
        let panelGone = { try await control.waitWindow("Debug Panel", present: false, timeout: 5) }
        // The menu's titles, a separator as "-", as the app builds it, kept with the evidence.
        let menuTitles = { (name: String) -> [String] in
          let titles = try await control.menu().map { $0.separator ? "-" : $0.title }
          try (titles.joined(separator: "\n") + "\n")
            .write(
              to: run.evidence.appendingPathComponent("\(name)-menu-items.txt"),
              atomically: true,
              encoding: .utf8
            )
          return titles
        }
        // The debug panel shows the run's times, pid and journal path, which change from run to
        // run, so its pictures are evidence rather than checkpoints.

        guard try await control.waitWindow("Advanced", timeout: 20) else {
          throw AppProcess.Failure("Settings never opened on the Advanced pane")
        }
        try await run.checkpoint("Advanced", "off")
        let off = try await menuTitles("off")
        run.check("the menu was read", true, off.contains("Settings…"))
        run.check(
          "the menu offers no Debug Panel while the switch is off",
          false,
          off.contains("Debug Panel")
        )
        run.check("the switch starts off", "0", try await switchValue())
        run.check(
          "Open Debug Panel is dimmed while the switch is off",
          false,
          try await buttonEnabled()
        )
        run.check(
          "no debug panel is open",
          true,
          try await control.waitWindow("Debug Panel", present: false, timeout: 0)
        )

        // Refused while dimmed, and forced through AppKit anyway it does nothing: the event path
        // itself honours the disabled state.
        run.check(
          "a click on the dimmed button is refused",
          "disabled",
          try await control.click(button).refused
        )
        let forced = try await control.click(button, force: true)
        run.check(
          "the click forced onto the dimmed button is posted and dispatched",
          [true, true],
          [forced.ok, forced["dispatched"]?.bool == true]
        )
        run.check(
          "a click forced onto the dimmed button opens nothing",
          false,
          try await panelOpen(1)
        )

        run.check("the click on the switch lands", true, try await control.click(toggle).ok)
        run.check(
          "the setting follows the switch",
          true,
          try await control.waitSetting("showDebugPanel", equals: .bool(true)).ok
        )
        run.check("the switch turns on", "1", try await run.settled("1", switchValue))
        run.check(
          "Open Debug Panel is live once the switch is on",
          true,
          try await run.settled(true, buttonEnabled)
        )
        try await run.checkpoint("Advanced", "on")
        let on = try await menuTitles("on")
        run.check("the menu was read with the switch on", true, on.contains("Settings…"))
        run.check(
          "the menu offers Debug Panel once the switch is on",
          true,
          on.contains("Debug Panel")
        )
        // Settings…, a separator, Debug Panel, a separator.
        let own = on.firstIndex(of: "Debug Panel").map { index in
          index >= 2 && index + 1 < on.count && on[index - 2] == "Settings…" && on[index - 1] == "-"
            && on[index + 1] == "-"
        }
        run.check("Debug Panel is in a group of its own after Settings…", true, own ?? false)

        _ = try await control.menu(press: "Debug Panel")
        run.check(
          "the menu's Debug Panel command opens the debug panel",
          true,
          try await panelOpen(5)
        )
        try await run.picture("Debug Panel", "panel-from-menu")
        run.check(
          "the panel's close button closes it",
          true,
          try await control.click(.subrole("AXCloseButton", in: "Debug Panel")).ok
        )
        guard try await panelGone() else {
          throw AppProcess.Failure("the debug panel would not close")
        }

        run.check("the click on Open Debug Panel lands", true, try await control.click(button).ok)
        run.check("Open Debug Panel opens the debug panel", true, try await panelOpen(5))
        try await run.picture("Debug Panel", "panel")

        _ = try await control.click(toggle)
        run.check(
          "the setting follows the switch off",
          true,
          try await control.waitSetting("showDebugPanel", equals: .bool(false)).ok
        )
        run.check("the switch turns off", "0", try await run.settled("0", switchValue))
        run.check("turning the switch off closes the debug panel", true, try await panelGone())
        run.check(
          "Open Debug Panel is dimmed again",
          false,
          try await run.settled(false, buttonEnabled)
        )
        let offAgain = try await menuTitles("off-again")
        run.check(
          "the menu was read with the switch off again",
          true,
          offAgain.contains("Settings…")
        )
        run.check(
          "turning the switch off takes Debug Panel out of the menu",
          false,
          offAgain.contains("Debug Panel")
        )
      }
    }
  }
#endif
