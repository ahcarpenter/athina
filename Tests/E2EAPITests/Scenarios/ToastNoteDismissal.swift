#if E2EAPI
  import AthinaControlProtocol
  import Testing

  extension Scenarios {
    /// A note that names a next step waits for the person rather than a timer, and comes down on
    /// their next key press or click.
    ///
    /// Started without the seeded Allow, a press of the talk-back shortcut (recorded first in
    /// Settings > General) brings up the note saying Athina is not allowed to watch and how to
    /// allow it. It is still up after the replay's clock moves a minute on, far past the reading
    /// time that takes an ordinary note down; a key press in one of Athina's windows takes it
    /// down, and so does a click outside Athina's windows for the next one. A hermetic run
    /// listens to nothing outside itself, so the key press is posted to Athina's own event queue
    /// (docs/e2e.md "The control API"); that a press in another app reaches it needs the
    /// Accessibility access Athina asks for and is not proven here.
    @Test func `toast-note-dismissal`() async {
      await Run.scenario(
        "toast-note-dismissal",
        arguments: ["--open", "settings:general"],
        consented: false
      ) { run in
        let control = run.control
        let note = "Athina note"
        let recorder = Target.identifier("voice.talkBackShortcut", in: "General")
        let talkBack = ControlValue.object(["keyCode": .number(17), "modifiers": .number(11)])
        let noteUp = { (present: Bool) in
          try await control.waitWindow(note, present: present, timeout: 5)
        }
        let noteText = {
          try await control.find(.everything(in: note)).flatMap(\.texts).joined(separator: "\n")
        }
        // Brings the note up with a press of the talk-back shortcut.
        let pressTalkBack = {
          guard try await control.hotKey("talk-back").ok, try await noteUp(true) else {
            throw AppProcess.Failure("a press of the talk-back shortcut brought up no note")
          }
        }

        guard try await control.waitWindow("General", timeout: 20) else {
          throw AppProcess.Failure("Settings never opened on the General pane")
        }
        guard try await control.click(recorder).ok,
          try await control.key(17, holding: [.control, .option, .command], in: "General").ok,
          try await control.waitSetting("mentor.pushToTalkHotKey", equals: talkBack).ok
        else { throw AppProcess.Failure("the talk-back shortcut could not be recorded") }

        try await pressTalkBack()
        run.check(
          "the note names the next step",
          true,
          try await noteText().contains("Choose Allow Watching in the Athina menu")
        )
        run.check(
          "the replay's clock moves a minute on",
          true,
          try await control.advance(seconds: 60).ok
        )
        run.check(
          "the note is still up, waiting for the person",
          false,
          try await control.waitWindow(note, present: false, timeout: 2)
        )
        // F19, a key that types nothing, pressed in one of Athina's windows.
        run.check(
          "a key is pressed",
          true,
          try await control.key(80, in: "General")["dispatched"]?.bool
        )
        run.check("the key press takes the note down", true, try await noteUp(false))

        try await pressTalkBack()
        run.check(
          "a click outside Athina's windows reaches the note",
          true,
          try await control.outsideClick(x: 40, y: 400)["heard"]?.bool
        )
        run.check("the click takes the note down", true, try await noteUp(false))
      }
    }
  }
#endif
