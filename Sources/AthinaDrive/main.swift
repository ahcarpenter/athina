import ArgumentParser
import Foundation

// athina-drive: the one implementation of every step an end-to-end scenario
// takes on the screen. Scenarios are shell scripts under scripts/e2e; they
// never talk to the accessibility tree, the pointer, or the journal directly.
//
// It drives whatever pid it is given and never looks up an app by name, so a
// run can never touch another lane's Athina or the owner's own copy.

// A bad command line exits 64 with its usage (swift-argument-parser's
// EX_USAGE) before anything is touched, and help exits 0.
var command: ParsableCommand
do {
  command = try AthinaDrive.parseAsRoot()
} catch {
  AthinaDrive.exit(withError: error)
}

// A command that only groups others, such as `click`, prints its help.
// Anything else a command throws is reported as a usage error too, so a
// drive step that cannot run never looks like one that ran and failed.
do {
  try command.run()
} catch {
  guard AthinaDrive.exitCode(for: error) == .failure else { AthinaDrive.exit(withError: error) }
  fail("athina-drive: \(error)", code: 64)
}
