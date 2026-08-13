import Foundation
import MicFlurryDomain
import SQLite3

public enum StorageError: Error, Equatable {
  case sqlite(code: Int32, message: String)
  case unsupportedDevice
  case invalidTimestamp(String)
}

public struct RecordingMetadata: Equatable, Sendable {
  public let id: Int64
  public let path: URL
  public let deviceID: DeviceID?
  public let sampleRate: UInt32
  public let sampleCount: UInt64
  public let startedAt: Date
  public let finishedAt: Date
}

public final class Store {
  private var database: OpaquePointer?

  public init(path: URL) throws {
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    var opened: OpaquePointer?
    let code = sqlite3_open_v2(
      path.path,
      &opened,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard code == SQLITE_OK else {
      let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
      sqlite3_close(opened)
      throw StorageError.sqlite(code: code, message: message)
    }
    database = opened
    do {
      try execute("PRAGMA journal_mode=WAL")
      try migrate()
    } catch {
      sqlite3_close(database)
      database = nil
      throw error
    }
  }

  deinit {
    sqlite3_close(database)
  }

  public func settings() throws -> Settings {
    let musicDirectory =
      FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: ".", isDirectory: true)
    return Settings(
      injectionDeviceUID: try value(for: "injection_device_uid") ?? "MicFlurry_2_UID",
      outputRateHz: UInt32(try value(for: "output_rate_hz") ?? "") ?? 48_000,
      inputGainDB: Float(try value(for: "input_gain_db") ?? "") ?? 12,
      recordingDirectory: try value(for: "recording_directory")
        ?? musicDirectory.appendingPathComponent("MicFlurry", isDirectory: true).path,
      autoRecord: try value(for: "auto_record") == "true"
    )
  }

  @discardableResult
  public func updateSettings(_ change: SettingsChange) throws -> Settings {
    try SettingsValidator.validate(change)
    try transaction {
      if let uid = change.injectionDeviceUID {
        try set(
          key: "injection_device_uid",
          value: uid.trimmingCharacters(in: .whitespacesAndNewlines)
        )
      }
      if let rate = change.outputRateHz {
        try set(key: "output_rate_hz", value: String(rate))
      }
      if let gain = change.inputGainDB {
        try set(key: "input_gain_db", value: String(gain))
      }
      if let directory = change.recordingDirectory {
        try set(
          key: "recording_directory",
          value: directory.trimmingCharacters(in: .whitespacesAndNewlines)
        )
      }
      if let enabled = change.autoRecord {
        try set(key: "auto_record", value: enabled ? "true" : "false")
      }
    }
    return try settings()
  }

  public func rememberDevice(_ device: Device, now: Date = Date()) throws {
    guard let model = device.support.model else { throw StorageError.unsupportedDevice }
    try transaction {
      try withStatement(
        """
        INSERT INTO known_devices(id, name, supports_atvv, supported_model, last_seen_at)
        VALUES (?1, ?2, ?3, ?4, ?5)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name,
          supports_atvv=excluded.supports_atvv,
          supported_model=excluded.supported_model,
          last_seen_at=excluded.last_seen_at
        """
      ) { statement in
        try bind(device.id.rawValue, to: 1, in: statement)
        try bind(device.name, to: 2, in: statement)
        try check(sqlite3_bind_int(statement, 3, device.supportsATVV ? 1 : 0))
        try bind(model, to: 4, in: statement)
        try bind(Self.timestamp(now), to: 5, in: statement)
        try stepToCompletion(statement)
      }
      try set(key: "last_connected_device_id", value: device.id.rawValue)
    }
  }

  public func lastConnectedDeviceID() throws -> DeviceID? {
    if let identifier = try value(for: "last_connected_device_id"),
      try supportedModel(for: identifier) != nil
    {
      return DeviceID(rawValue: identifier)
    }
    return try withStatement(
      """
      SELECT id FROM known_devices
      WHERE supported_model IS NOT NULL
      ORDER BY last_seen_at DESC LIMIT 1
      """
    ) { statement in
      guard try stepHasRow(statement) else { return nil }
      return columnText(statement, at: 0).map { DeviceID(rawValue: $0) }
    }
  }

  public func isKnown(deviceID: DeviceID) throws -> Bool {
    try withStatement("SELECT 1 FROM known_devices WHERE id=?1") { statement in
      try bind(deviceID.rawValue, to: 1, in: statement)
      return try stepHasRow(statement)
    }
  }

  public func addRecording(
    path: URL,
    deviceID: DeviceID?,
    sampleRate: UInt32,
    sampleCount: UInt64,
    startedAt: Date,
    finishedAt: Date
  ) throws {
    try withStatement(
      """
      INSERT INTO recordings(
        path, device_id, sample_rate_hz, sample_count, started_at, finished_at
      ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """
    ) { statement in
      try bind(path.path, to: 1, in: statement)
      if let deviceID {
        try bind(deviceID.rawValue, to: 2, in: statement)
      } else {
        try check(sqlite3_bind_null(statement, 2))
      }
      try check(sqlite3_bind_int64(statement, 3, Int64(sampleRate)))
      guard let signedCount = Int64(exactly: sampleCount) else {
        throw StorageError.sqlite(code: SQLITE_TOOBIG, message: "sample count exceeds SQLite int64")
      }
      try check(sqlite3_bind_int64(statement, 4, signedCount))
      try bind(Self.timestamp(startedAt), to: 5, in: statement)
      try bind(Self.timestamp(finishedAt), to: 6, in: statement)
      try stepToCompletion(statement)
    }
  }

  public func recordings() throws -> [RecordingMetadata] {
    try withStatement(
      """
      SELECT id, path, device_id, sample_rate_hz, sample_count, started_at, finished_at
      FROM recordings ORDER BY id DESC
      """
    ) { statement in
      var result: [RecordingMetadata] = []
      while try stepHasRow(statement) {
        let startedText = columnText(statement, at: 5) ?? ""
        let finishedText = columnText(statement, at: 6) ?? ""
        guard let startedAt = Self.date(from: startedText) else {
          throw StorageError.invalidTimestamp(startedText)
        }
        guard let finishedAt = Self.date(from: finishedText) else {
          throw StorageError.invalidTimestamp(finishedText)
        }
        let storedRate = sqlite3_column_int64(statement, 3)
        let storedCount = sqlite3_column_int64(statement, 4)
        guard let sampleRate = UInt32(exactly: storedRate),
          let sampleCount = UInt64(exactly: storedCount)
        else {
          throw StorageError.sqlite(
            code: SQLITE_MISMATCH,
            message: "recording metadata contains an invalid sample rate or count"
          )
        }
        result.append(
          RecordingMetadata(
            id: sqlite3_column_int64(statement, 0),
            path: URL(fileURLWithPath: columnText(statement, at: 1) ?? ""),
            deviceID: columnText(statement, at: 2).map { DeviceID(rawValue: $0) },
            sampleRate: sampleRate,
            sampleCount: sampleCount,
            startedAt: startedAt,
            finishedAt: finishedAt
          )
        )
      }
      return result
    }
  }

  var userVersion: Int32 {
    get throws {
      try withStatement("PRAGMA user_version") { statement in
        guard try stepHasRow(statement) else { return 0 }
        return sqlite3_column_int(statement, 0)
      }
    }
  }

  private func migrate() throws {
    try transaction {
      try execute(
        """
        CREATE TABLE IF NOT EXISTS settings (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS known_devices (
          id TEXT PRIMARY KEY NOT NULL,
          name TEXT NOT NULL,
          supports_atvv INTEGER NOT NULL,
          supported_model TEXT,
          last_seen_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS recordings (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          path TEXT UNIQUE NOT NULL,
          device_id TEXT,
          sample_rate_hz INTEGER NOT NULL,
          sample_count INTEGER NOT NULL,
          started_at TEXT NOT NULL,
          finished_at TEXT NOT NULL
        );
        """
      )
      let hasSupportedModel = try withStatement(
        """
        SELECT EXISTS(
          SELECT 1 FROM pragma_table_info('known_devices') WHERE name='supported_model'
        )
        """
      ) { statement in
        guard try stepHasRow(statement) else { return false }
        return sqlite3_column_int(statement, 0) != 0
      }
      if !hasSupportedModel {
        try execute("ALTER TABLE known_devices ADD COLUMN supported_model TEXT")
      }
      try execute("PRAGMA user_version=2")
    }
  }

  private func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  private func value(for key: String) throws -> String? {
    try withStatement("SELECT value FROM settings WHERE key=?1") { statement in
      try bind(key, to: 1, in: statement)
      guard try stepHasRow(statement) else { return nil }
      return columnText(statement, at: 0)
    }
  }

  private func set(key: String, value: String) throws {
    try withStatement(
      """
      INSERT INTO settings(key, value) VALUES (?1, ?2)
      ON CONFLICT(key) DO UPDATE SET value=excluded.value
      """
    ) { statement in
      try bind(key, to: 1, in: statement)
      try bind(value, to: 2, in: statement)
      try stepToCompletion(statement)
    }
  }

  private func supportedModel(for identifier: String) throws -> String? {
    try withStatement("SELECT supported_model FROM known_devices WHERE id=?1") { statement in
      try bind(identifier, to: 1, in: statement)
      guard try stepHasRow(statement) else { return nil }
      return columnText(statement, at: 0)
    }
  }

  private func execute(_ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(database, sql, nil, nil, &errorMessage)
    guard code == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? databaseMessage()
      sqlite3_free(errorMessage)
      throw StorageError.sqlite(code: code, message: message)
    }
  }

  private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
    var statement: OpaquePointer?
    try check(sqlite3_prepare_v2(database, sql, -1, &statement, nil))
    guard let statement else {
      throw StorageError.sqlite(code: SQLITE_ERROR, message: "SQLite returned no statement")
    }
    defer { sqlite3_finalize(statement) }
    return try body(statement)
  }

  private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    try check(sqlite3_bind_text(statement, index, value, -1, transient))
  }

  private func stepHasRow(_ statement: OpaquePointer) throws -> Bool {
    let code = sqlite3_step(statement)
    if code == SQLITE_ROW { return true }
    if code == SQLITE_DONE { return false }
    throw StorageError.sqlite(code: code, message: databaseMessage())
  }

  private func stepToCompletion(_ statement: OpaquePointer) throws {
    let code = sqlite3_step(statement)
    guard code == SQLITE_DONE else {
      throw StorageError.sqlite(code: code, message: databaseMessage())
    }
  }

  private func check(_ code: Int32) throws {
    guard code == SQLITE_OK else {
      throw StorageError.sqlite(code: code, message: databaseMessage())
    }
  }

  private func databaseMessage() -> String {
    database.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
  }

  private func columnText(_ statement: OpaquePointer, at index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
      let text = sqlite3_column_text(statement, index)
    else { return nil }
    return String(cString: text)
  }

  private static func timestamp(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private static func date(from timestamp: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
  }
}
