#if E2EAPI
  import AthinaControlProtocol
  import Testing

  extension Scenarios {
    /// The Settings shortcut recorders record, refuse the other shortcut with an alert, and clear
    /// on Delete.
    ///
    /// The keyboard shortcut recorders in Settings (docs/mentor-loop.md "Keyboard shortcuts"):
    /// Settings > General's talk-back recorder takes a combination pressed while it records into
    /// the settings, refuses the pause shortcut's combination with an alert that says why, keeping
    /// what it had, and clears on Delete; Settings > Privacy's pause recorder clears on Delete
    /// too, which turns the pause shortcut off while settings.json keeps its combination for
    /// earlier builds, and records it again. Every click is simulated inside Athina, through
    /// AppKit's own event path, and every key press is posted to its event queue (`key`), where
    /// the recorder's own event monitor takes it as it takes a person's. A hermetic run registers
    /// no shortcut with the system, so what a press of one does outside the recorder is not this
    /// scenario's to prove.
    @Test func `shortcut-recorder`() async {
      await Run.scenario("shortcut-recorder", arguments: ["--open", "settings:general"]) { run in
        let control = run.control
        // Virtual key codes.
        let keyT = 17
        let keyP = 35
        let delete = 51
        let escape = 53
        let held: [ControlProtocol.Modifier] = [.control, .option, .command]
        // Control-Option-Command-T and -P as settings.json holds them.
        let talkBack = ControlValue.object(["keyCode": .number(17), "modifiers": .number(11)])
        let pause = ControlValue.object(["keyCode": .number(35), "modifiers": .number(11)])
        let talkBackRecorder = Target.identifier("voice.talkBackShortcut", in: "General")
        let pauseRecorder = Target.identifier("privacy.pauseShortcut", in: "Privacy")

        let talkBackField = { try await control.first(talkBackRecorder)?.value ?? "" }
        let pauseField = { try await control.first(pauseRecorder)?.value ?? "" }
        // The window level of the General window, which a hermetic run keeps below the desktop
        // picture whatever the app asks for, such as the modal level AppKit raises a window to
        // while an alert's sheet runs on it.
        let generalLevel = {
          try await control.windows().first { $0.title == "General" }?.level
        }
        let sheets = { try await control.find(.role("AXSheet", in: "General")).count }
        let texts = { (window: String) in
          try await control.find(.role("AXStaticText", in: window)).map(\.value)
        }
        // The menu's Pause Watching or Resume Watching, whichever it offers.
        let menuToggle = {
          try await control.menu().first {
            ["Pause Watching", "Resume Watching"].contains($0.title)
          }?.title
        }

        guard try await control.waitWindow("General", timeout: 20) else {
          throw AppProcess.Failure("Settings never opened on the General pane")
        }

        // 1 the talk-back recorder records a combination.
        run.check(
          "the talk-back shortcut starts unset",
          .null,
          try await control.setting("mentor.pushToTalkHotKey")
        )
        run.check(
          "a click on the talk-back recorder lands",
          true,
          try await control.click(talkBackRecorder).ok
        )
        run.check(
          "Control-Option-Command-T is pressed",
          true,
          try await control.key(keyT, holding: held, in: "General")["dispatched"]?.bool
        )
        run.check(
          "the settings hold it",
          true,
          try await control.waitSetting("mentor.pushToTalkHotKey", equals: talkBack).ok
        )
        run.check("the recorder shows it", "⌃⌥⌘T", try await run.settled("⌃⌥⌘T", talkBackField))

        // 2 the pause shortcut's combination is refused with an alert.
        let parked = try await generalLevel()
        run.check(
          "a click on the talk-back recorder lands",
          true,
          try await control.click(talkBackRecorder).ok
        )
        _ = try await control.key(keyP, holding: held, in: "General")
        run.check("an alert comes up over the pane", 1, try await run.settled(1, sheets))
        run.check(
          "the alert says the pause shortcut has it",
          true,
          try await texts("General").contains(
            "This keyboard shortcut is already the pause shortcut."
          )
        )
        run.check("the pane stays parked while the alert is up", parked, try await generalLevel())
        try await run.checkpoint("General", "talk-back-refused")
        run.check(
          "a click on the alert's OK lands",
          true,
          try await control.click(.role("AXButton", label: "OK", in: "General")).ok
        )
        run.check("the alert goes", 0, try await run.settled(0, sheets))
        run.check("the pane stays parked once it has gone", parked, try await generalLevel())
        run.check(
          "the settings keep the talk-back shortcut",
          talkBack,
          try await control.setting("mentor.pushToTalkHotKey")
        )
        run.check("the recorder still shows it", "⌃⌥⌘T", try await talkBackField())

        // 3 Delete clears the talk-back shortcut.
        run.check(
          "a click on the talk-back recorder lands",
          true,
          try await control.click(talkBackRecorder).ok
        )
        run.check(
          "Delete is pressed",
          true,
          try await control.key(delete, in: "General")["dispatched"]?.bool
        )
        run.check(
          "the settings hold no talk-back shortcut",
          true,
          try await control.waitSetting("mentor.pushToTalkHotKey", equals: .null).ok
        )
        run.check("the recorder is empty", "", try await run.settled("", talkBackField))
        _ = try await control.key(escape, in: "General")

        // 4 Delete clears the pause shortcut.
        run.check(
          "a click on the Privacy toolbar item lands",
          true,
          try await control.click(.label("Privacy", in: "General")).ok
        )
        guard try await control.waitWindow("Privacy", timeout: 5) else {
          throw AppProcess.Failure("the Privacy pane never opened")
        }
        run.check(
          "the pause recorder shows its combination",
          "⌃⌥⌘P",
          try await run.settled("⌃⌥⌘P", pauseField)
        )
        run.check(
          "a press of the pause shortcut is heard",
          true,
          try await control.hotKey("pause").ok
        )
        run.check("which pauses watching", "Resume Watching", try await menuToggle())
        _ = try await control.hotKey("pause")
        run.check(
          "a click on the pause recorder lands",
          true,
          try await control.click(pauseRecorder).ok
        )
        run.check(
          "Delete is pressed",
          true,
          try await control.key(delete, in: "Privacy")["dispatched"]?.bool
        )
        run.check(
          "the settings hold the pause shortcut cleared",
          true,
          try await control.waitSetting("pauseHotKeyCleared", equals: .bool(true)).ok
        )
        run.check(
          "and keep its combination for earlier builds",
          pause,
          try await control.setting("pauseHotKey")
        )
        run.check("the recorder is empty", "", try await run.settled("", pauseField))
        run.check(
          "the pane says nothing is wrong",
          false,
          try await texts("Privacy").contains {
            $0.hasPrefix("Another app uses this combination")
          }
        )
        run.check(
          "a press of it is refused as not registered",
          "disabled",
          try await control.hotKey("pause").refused
        )
        run.check("watching goes on", "Pause Watching", try await menuToggle())
        _ = try await control.key(escape, in: "Privacy")
        try await run.picture("Privacy", "pause-cleared")

        // 5 the pause recorder records it again.
        run.check(
          "a click on the pause recorder lands",
          true,
          try await control.click(pauseRecorder).ok
        )
        run.check(
          "Control-Option-Command-P is pressed",
          true,
          try await control.key(keyP, holding: held, in: "Privacy")["dispatched"]?.bool
        )
        run.check(
          "the settings hold it set",
          true,
          try await control.waitSetting("pauseHotKeyCleared", equals: .bool(false)).ok
        )
        run.check("the recorder shows it", "⌃⌥⌘P", try await run.settled("⌃⌥⌘P", pauseField))
        run.check("a press of it is heard", true, try await control.hotKey("pause").ok)
        run.check("which pauses watching", "Resume Watching", try await menuToggle())
      }
    }
  }
#endif
