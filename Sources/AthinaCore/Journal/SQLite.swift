import AthinaSQLiteShim
import Foundation
import SQLite3

/// An error SQLite returned, with its result code and message.
public struct SQLiteError: Error, CustomStringConvertible, Sendable {
  /// The SQLite result code, such as `SQLITE_BUSY`.
  public let code: Int32
  /// SQLite's message for the error, often prefixed with the step that
  /// failed, such as "prepare".
  public let message: String
  /// The code and message, reading like "SQLite error 5: database is locked".
  public var description: String { "SQLite error \(code): \(message)" }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A thin, non-Sendable wrapper over the system SQLite C API.
///
/// Owned by `Journal`.
final class SQLiteConnection {
  private var db: OpaquePointer?

  /// `create` is false for a database that must already be there, so a
  /// wrong path is an error rather than a new, empty file.
  init(path: String, create: Bool = true) throws {
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_FULLMUTEX
    let rc = sqlite3_open_v2(path, &handle, flags, nil)
    guard rc == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
      if let handle { sqlite3_close(handle) }
      throw SQLiteError(code: rc, message: message)
    }
    db = handle
    sqlite3_busy_timeout(handle, 2000)
  }

  deinit {
    if let db { sqlite3_close(db) }
  }

  /// Leaves the write-ahead log as it was found when this connection
  /// closes, rather than folding it into the database file: for a database
  /// that is only being read and must stay byte for byte what it was.
  func keepWriteAheadLogOnClose() throws {
    try check(athina_sqlite_keep_wal_on_close(db), "keep the write-ahead log on close")
  }

  private func check(_ rc: Int32, _ context: String) throws {
    guard rc == SQLITE_OK || rc == SQLITE_DONE || rc == SQLITE_ROW else {
      throw SQLiteError(code: rc, message: "\(context): \(String(cString: sqlite3_errmsg(db)))")
    }
  }

  func execute(_ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
    if rc != SQLITE_OK {
      let message = errorMessage.map { String(cString: $0) } ?? "unknown"
      sqlite3_free(errorMessage)
      throw SQLiteError(code: rc, message: message)
    }
  }

  enum Value {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
  }

  final class Statement {
    fileprivate let handle: OpaquePointer

    fileprivate init(handle: OpaquePointer) { self.handle = handle }
    deinit { sqlite3_finalize(handle) }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }
    func text(_ column: Int32) -> String? {
      guard let cString = sqlite3_column_text(handle, column) else { return nil }
      return String(cString: cString)
    }
    func blob(_ column: Int32) -> Data? {
      let length = Int(sqlite3_column_bytes(handle, column))
      guard length > 0, let bytes = sqlite3_column_blob(handle, column) else {
        return sqlite3_column_type(handle, column) == SQLITE_NULL ? nil : Data()
      }
      return Data(bytes: bytes, count: length)
    }
  }

  private func prepare(_ sql: String, _ values: [Value]) throws -> Statement {
    var handle: OpaquePointer?
    try check(sqlite3_prepare_v2(db, sql, -1, &handle, nil), "prepare")
    guard let handle else {
      throw SQLiteError(code: SQLITE_ERROR, message: "prepare returned no statement")
    }
    let statement = Statement(handle: handle)
    for (index, value) in values.enumerated() {
      let position = Int32(index + 1)
      let rc: Int32
      switch value {
      case .null: rc = sqlite3_bind_null(handle, position)
      case .int(let v): rc = sqlite3_bind_int64(handle, position, v)
      case .double(let v): rc = sqlite3_bind_double(handle, position, v)
      case .text(let v): rc = sqlite3_bind_text(handle, position, v, -1, sqliteTransient)
      case .blob(let v):
        rc = v.withUnsafeBytes { buffer in
          sqlite3_bind_blob(
            handle,
            position,
            buffer.baseAddress,
            Int32(buffer.count),
            sqliteTransient
          )
        }
      }
      try check(rc, "bind \(position)")
    }
    return statement
  }

  /// Runs a statement that returns no rows.
  func run(_ sql: String, _ values: [Value] = []) throws {
    let statement = try prepare(sql, values)
    try check(sqlite3_step(statement.handle), "step")
  }

  /// Runs a query and maps each row.
  func query<T>(_ sql: String, _ values: [Value] = [], _ map: (Statement) throws -> T) throws -> [T]
  {
    let statement = try prepare(sql, values)
    var rows: [T] = []
    while true {
      let rc = sqlite3_step(statement.handle)
      if rc == SQLITE_ROW {
        rows.append(try map(statement))
      } else {
        try check(rc, "step")
        break
      }
    }
    return rows
  }

  func scalarInt(_ sql: String, _ values: [Value] = []) throws -> Int64 {
    try query(sql, values) { $0.int(0) }.first ?? 0
  }

  var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }
  var changes: Int { Int(sqlite3_changes(db)) }
}
