import Foundation
import GRDB

/// Runs `sql`, one or more statements, against the SQLite file at `url`
/// through a connection of its own, creating the file if needed: how a test
/// leaves a journal the way an older build, or another app, would have.
func runSQL(at url: URL, _ sql: String) throws {
  try DatabaseQueue(path: url.path).writeWithoutTransaction { try $0.execute(sql: sql) }
}
