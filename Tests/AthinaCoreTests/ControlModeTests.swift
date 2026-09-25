import Foundation
import Testing

@testable import AthinaCore

@Suite struct ControlModeTests {
  let replay = ModelClientMode.replay(
    directory: URL(fileURLWithPath: "/fixtures"),
    allowStale: false
  )
  let unsandboxed = RuntimeEnvironment(isSandboxed: false)
  let secret = String(repeating: "a1", count: 32)

  func mode(
    _ arguments: [String],
    client: ModelClientMode? = nil,
    environment: RuntimeEnvironment? = nil,
    compiledIn: Bool = true,
    directory: ControlDirectory? = nil
  ) -> ControlMode {
    let facts = directory ?? ControlDirectory(kind: .directory, secret: secret)
    return ControlMode(
      arguments: ["Athina"] + arguments,
      clientMode: client ?? replay,
      environment: environment ?? unsandboxed,
      compiledIn: compiledIn,
      inspect: { _ in facts }
    )
  }

  @Test func noFlagMeansOff() {
    #expect(mode(["--replay", "/fixtures"]) == .off)
    #expect(mode([], client: .live, compiledIn: false) == .off)
  }

  @Test func aReplayInAHarnessDirectoryIsServed() {
    let served = mode(["--replay", "/fixtures", "--control", "/tmp/athina-ctl.abc"])
    #expect(
      served
        == .on(
          ControlChannel(
            directory: URL(fileURLWithPath: "/tmp/athina-ctl.abc", isDirectory: true),
            secret: secret
          )
        )
    )
    #expect(served.refusal == nil)
  }

  /// A real-screen check drives a served launch too, so it stays on the
  /// screen and in the menu bar unless asked to be hermetic.
  @Test func aServedLaunchIsHermeticOnlyWhenAsked() {
    let served = mode(["--replay", "/fixtures", "--control", "/tmp/athina-ctl.abc"])
    #expect(!served.isHermetic)
    #expect(!served.parksWindows)
    let hermetic = mode(["--replay", "/fixtures", "--control", "/tmp/athina-ctl.abc", "--hermetic"])
    #expect(hermetic.isHermetic)
    #expect(hermetic.parksWindows)
  }

  @Test func showWindowsLeavesAHermeticRunsWindowsOnScreen() {
    let shown = mode([
      "--replay", "/fixtures", "--control", "/tmp/athina-ctl.abc", "--hermetic", "--show-windows",
    ])
    #expect(shown.isHermetic)
    #expect(!shown.parksWindows)
    // Without --hermetic nothing is parked to leave on screen.
    #expect(!mode(["--control", "/tmp/athina-ctl.abc", "--show-windows"]).parksWindows)
  }

  /// A refused `--control` leaves the launch as it would be without it, so
  /// a live launch given the flags still senses and shows itself.
  @Test func onlyAServedLaunchIsHermetic() {
    #expect(!ControlMode.off.isHermetic)
    #expect(!mode(["--control", "/tmp/c", "--hermetic"], client: .live).isHermetic)
    #expect(!mode(["--control", "/tmp/c", "--hermetic"], compiledIn: false).parksWindows)
  }

  @Test func aBuildWithoutTheTraitRefusesWhateverElseIsTrue() {
    let refused = mode(["--control", "/tmp/c"], compiledIn: false)
    #expect(refused.refusal?.contains("built without the control API") == true)
  }

  @Test(arguments: [
    ModelClientMode.live, .record(directory: URL(fileURLWithPath: "/r")), .invalid("contradictory"),
  ])
  func onlyAReplayIsServed(client: ModelClientMode) {
    #expect(
      mode(["--control", "/tmp/c"], client: client).refusal == "--control applies only to --replay"
    )
  }

  @Test func aSandboxedProcessRefuses() {
    let sandboxed = RuntimeEnvironment(
      isSandboxed: true,
      containerURL: URL(fileURLWithPath: "/container")
    )
    #expect(
      mode(["--control", "/tmp/c"], environment: sandboxed).refusal?.contains("sandboxed") == true
    )
  }

  @Test func theDirectoryMustBeGivenAndAbsolute() {
    #expect(mode(["--control"]).refusal?.contains("needs the directory") == true)
    #expect(mode(["--control", "--replay"]).refusal?.contains("needs the directory") == true)
    #expect(mode(["--control", "relative/dir"]).refusal?.contains("absolute") == true)
  }

  @Test func theSocketPathMustFit() {
    let long = "/" + String(repeating: "d", count: ControlMode.socketPathLimit)
    #expect(mode(["--control", long]).refusal?.contains("socket path is at most") == true)
    // Exactly at the limit is fine.
    let fits =
      "/"
      + String(
        repeating: "d",
        count: ControlMode.socketPathLimit - ControlMode.socketName.count - 2
      )
    #expect(mode(["--control", fits]).refusal == nil)
  }

  @Test func theDirectoryMustBeTheHarnesssOwn() {
    let cases: [(ControlDirectory, String)] = [
      (ControlDirectory(kind: .missing), "no such directory"),
      (ControlDirectory(kind: .notADirectory), "not a directory"),
      (
        ControlDirectory(kind: .directory, ownedByUser: false, secret: secret), "owned by this user"
      ),
      (
        ControlDirectory(kind: .directory, permissions: 0o755, secret: secret),
        "exactly 0700, not 755"
      ),
      (
        ControlDirectory(kind: .directory, permissions: 0o710, secret: secret),
        "exactly 0700, not 710"
      ),
      (
        ControlDirectory(kind: .directory, permissions: 0o500, secret: secret),
        "exactly 0700, not 500"
      ),
      (ControlDirectory(kind: .directory), "holds no secret file"),
      (
        ControlDirectory(kind: .directory, secretFileIsPrivate: false, secret: secret),
        "no one else can read"
      ),
      (ControlDirectory(kind: .directory, secret: "short"), "at least 32 characters"),
    ]
    for (facts, expected) in cases {
      let refusal = mode(["--control", "/tmp/c"], directory: facts).refusal ?? ""
      #expect(refusal.contains(expected), "\(facts) gave \"\(refusal)\"")
      #expect(refusal.hasSuffix("/tmp/c"), "the path comes last: \(refusal)")
    }
  }

  @Test func inspectReadsARealDirectory() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "control-mode-\(UUID().uuidString.prefix(8))"
    )
    defer { try? FileManager.default.removeItem(at: base) }
    let directory = base.appendingPathComponent("ctl")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #expect(chmod(directory.path, 0o700) == 0)
    #expect(
      ControlDirectory.inspect(directory) == ControlDirectory(kind: .directory, permissions: 0o700)
    )

    let secretURL = directory.appendingPathComponent(ControlMode.secretName)
    try (secret + "\n").write(to: secretURL, atomically: true, encoding: .utf8)
    #expect(chmod(secretURL.path, 0o600) == 0)
    #expect(
      ControlDirectory.inspect(directory)
        == ControlDirectory(kind: .directory, permissions: 0o700, secret: secret)
    )

    #expect(chmod(secretURL.path, 0o644) == 0)
    #expect(ControlDirectory.inspect(directory).secretFileIsPrivate == false)
    #expect(chmod(directory.path, 0o755) == 0)
    #expect(ControlDirectory.inspect(directory).permissions == 0o755)

    let link = base.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
    #expect(ControlDirectory.inspect(link).kind == .notADirectory)
    #expect(ControlDirectory.inspect(base.appendingPathComponent("absent")).kind == .missing)
  }
}
