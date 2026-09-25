import AppKit
import ApplicationServices
import AthinaE2E
import Foundation

// athina-drive: the one implementation of every step an end-to-end scenario
// takes on the screen. Scenarios are shell scripts under scripts/e2e; they
// never talk to the accessibility tree, the pointer, or the journal directly.
//
// It drives whatever pid it is given and never looks up an app by name, so a
// run can never touch another lane's Athina or the owner's own copy.

let invocation: DriveInvocation
do {
  invocation = try DriveArguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as DriveUsageError {
  fail(error.description, code: 64)
} catch {
  fail("athina-drive: \(error)", code: 64)
}

// One place turns a bad argument into a usage message and exit 64, so a
// mistyped drive step never reaches the pointer or the accessibility tree.
do {
  try run(invocation)
} catch let error as DriveUsageError {
  fail(error.description, code: 64)
} catch {
  fail("athina-drive \(invocation.command): \(error)", code: 64)
}

@MainActor
func run(_ invocation: DriveInvocation) throws {
  switch invocation.command {
  case "permissions":
    // Neither grant can be given from a shell; a run that is missing one has
    // to say so rather than fail later with an empty window list.
    say("accessibility=\(AXIsProcessTrusted() ? "yes" : "no")")
    say("screenRecording=\(CGPreflightScreenCaptureAccess() ? "yes" : "no")")

  case "ready":
    let ready = statusItem(of: try invocation.pid(0)) != nil
    say(ready ? "READY" : "NOT READY")
    exit(ready ? 0 : 2)

  case "windows":
    let pid = try invocation.pid(0)
    for window in onScreenWindows() where window.pid == pid {
      say(window.description)
    }

  case "toast":
    let pid = try invocation.pid(0)
    guard let toast = toastWindow(of: pid) else { exit(2) }
    say("\(toast.id)")

  case "bar":
    Bar.report(pid: invocation.positionals.isEmpty ? nil : try invocation.pid(0))

  case "front":
    let front = NSWorkspace.shared.frontmostApplication
    say("frontmost app=\"\(front?.localizedName ?? "?")\" pid=\(front?.processIdentifier ?? -1)")

  case "activate":
    let pid = try invocation.pid(0)
    guard let app = NSRunningApplication(processIdentifier: pid) else {
      fail("activate: no pid \(pid)", code: 2)
    }
    let activated = app.activate()
    usleep(400_000)
    let front = NSWorkspace.shared.frontmostApplication
    say(
      """
      activate -> \(activated); frontmost now \"\(front?.localizedName ?? "?")\" \
      pid=\(front?.processIdentifier ?? -1)
      """
    )

  case "ax":
    try Accessibility.run(invocation)

  case "click":
    let kind = try invocation.positional(0)
    let shot = invocation.option("--shot")
    switch kind {
    case "item":
      Clicker.perform(.statusItem(pid: try invocation.pid(1)), shot: shot)
    case "at":
      Clicker.perform(
        .emptyBar(point: CGPoint(x: try invocation.number(1), y: try invocation.number(2))),
        shot: shot
      )
    case "window":
      Clicker.perform(
        .window(
          pid: try invocation.pid(1),
          point: CGPoint(x: try invocation.number(2), y: try invocation.number(3))
        ),
        shot: shot
      )
    default:
      fail("click: expected item, at, or window, got \"\(kind)\"", code: 64)
    }

  case "raise":
    // By pid and window title, never by app name: another lane's app, or
    // the owner's own, must never be brought forward by a scenario.
    let pid = try invocation.pid(0)
    let wanted = invocation.positionals.count > 1 ? invocation.positionals[1] : ""
    let app = AXUIElementCreateApplication(pid)
    let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    guard
      let window = windows.first(where: {
        wanted.isEmpty || title($0).localizedCaseInsensitiveContains(wanted)
      })
    else {
      fail("raise: pid \(pid) has no window matching \"\(wanted)\"", code: 2)
    }
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    say("raised \"\(title(window))\" of pid \(pid) -> \(raised.rawValue)")

  case "close":
    let pid = try invocation.pid(0)
    let wanted = try invocation.positional(1)
    let app = AXUIElementCreateApplication(pid)
    let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    guard let window = windows.first(where: { title($0).localizedCaseInsensitiveContains(wanted) })
    else {
      say("close: pid \(pid) has no window matching \"\(wanted)\"")
      exit(2)
    }
    guard let button = attr(window, kAXCloseButtonAttribute) else {
      fail("close: \"\(title(window))\" has no close button", code: 2)
    }
    let closed = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    say("closed \"\(title(window))\" of pid \(pid) -> \(closed.rawValue)")

  case "menupick":
    Clicker.menuPick(
      pid: try invocation.pid(0),
      row: try invocation.positional(1),
      item: try invocation.positional(2)
    )

  case "tap":
    let kind = try invocation.positional(0)
    switch kind {
    case "session": Watchers.tap(pid: nil)
    case "pid": Watchers.tap(pid: try invocation.pid(1))
    default: fail("tap: expected session or pid, got \"\(kind)\"", code: 64)
    }

  case "announce":
    Watchers.announcements(pid: try invocation.pid(0))

  case "flip":
    FlipWindow.run(
      frame: CGRect(
        x: try invocation.number(0),
        y: try invocation.number(1),
        width: try invocation.number(2),
        height: try invocation.number(3)
      )
    )

  case "journal":
    JournalReader.run(database: try invocation.positional(0), query: try invocation.positional(1))

  case "key":
    Pointer.key(
      CGKeyCode(try invocation.number(0)),
      command: invocation.flag("--cmd"),
      shift: invocation.flag("--shift")
    )

  case "shot":
    let kind = try invocation.positional(0)
    switch kind {
    case "window":
      let id = try invocation.positional(1)
      screencapture(["-x", "-o", "-l", id, try invocation.positional(2)])
      say("window \(id) -> \(try invocation.positional(2))")
    case "region":
      let region =
        "\(Int(try invocation.number(1))),\(Int(try invocation.number(2)))"
        + ",\(Int(try invocation.number(3))),\(Int(try invocation.number(4)))"
      screencapture(["-x", "-o", "-R", region, try invocation.positional(5)])
      say("region \(region) -> \(try invocation.positional(5))")
    default:
      fail("shot: expected window or region, got \"\(kind)\"", code: 64)
    }

  default:
    fail(DriveArguments.usage(), code: 64)
  }
}
