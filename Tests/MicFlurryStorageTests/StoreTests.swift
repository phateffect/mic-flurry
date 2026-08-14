import Foundation
import MicFlurryDomain
import SQLite3
import Testing

@testable import MicFlurryStorage

@Test func persistsSettingsUsingAcceptedDefaultsAndSchema() throws {
  let fixture = try DatabaseFixture()
  defer { fixture.remove() }
  let store = try Store(path: fixture.databaseURL)
  #expect(try store.userVersion == 2)
  #expect(try store.settings().inputGainDB == 12)

  try store.updateSettings(
    SettingsChange(outputRateHz: 16_000, inputGainDB: 9, autoRecord: true)
  )
  let reopened = try Store(path: fixture.databaseURL)
  let settings = try reopened.settings()
  #expect(settings.outputRateHz == 16_000)
  #expect(settings.inputGainDB == 9)
  #expect(settings.autoRecord)
}

@Test func persistsKeyChordSettingsWithDefaults() throws {
  let fixture = try DatabaseFixture()
  defer { fixture.remove() }
  let store = try Store(path: fixture.databaseURL)
  let defaults = try store.settings()
  #expect(defaults.dictationStartChord == "fn")
  #expect(defaults.dictationEndChord.isEmpty)
  #expect(defaults.dictationMode == "hold")
  #expect(defaults.actionChords.isEmpty)

  try store.updateSettings(
    SettingsChange(
      dictationStartChord: "ctrl+ctrl", dictationMode: "tap",
      actionChords: ["select": "return", "volume_up": "a"])
  )
  let reopened = try Store(path: fixture.databaseURL)
  let settings = try reopened.settings()
  #expect(settings.dictationStartChord == "ctrl+ctrl")
  #expect(settings.dictationEndChord.isEmpty)
  #expect(settings.dictationMode == "tap")
  #expect(settings.actionChords == ["select": "return", "volume_up": "a"])

  #expect(throws: SettingsValidationError.invalidKeyChord("not-a-key")) {
    try store.updateSettings(SettingsChange(actionChords: ["volume_up": "not-a-key"]))
  }
  #expect(throws: SettingsValidationError.invalidChordAction("power")) {
    try store.updateSettings(SettingsChange(actionChords: ["power": "a"]))
  }
  #expect(throws: SettingsValidationError.invalidDictationMode("toggle")) {
    try store.updateSettings(SettingsChange(dictationMode: "toggle"))
  }
}

@Test func migratesLegacyKnownDevicesWithoutTrustingThem() throws {
  let fixture = try DatabaseFixture()
  defer { fixture.remove() }
  let testFile = URL(fileURLWithPath: #filePath)
  let migrationFixture =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sqlite-v1.sql")
  try fixture.execute(String(contentsOf: migrationFixture, encoding: .utf8))
  let store = try Store(path: fixture.databaseURL)
  #expect(try store.userVersion == 2)
  #expect(try store.lastConnectedDeviceID() == nil)
}

@Test func remembersOnlySupportedDevicesAndRestoresLatest() throws {
  let fixture = try DatabaseFixture()
  defer { fixture.remove() }
  let store = try Store(path: fixture.databaseURL)
  let unsupported = Device(id: DeviceID(rawValue: "unsupported"), name: "Unknown")
  #expect(throws: StorageError.unsupportedDevice) {
    try store.rememberDevice(unsupported)
  }

  let supported = Device(
    id: DeviceID(rawValue: "rc003"),
    name: "Remote",
    connected: true,
    supportsATVV: true,
    support: .supported(model: "RC003")
  )
  try store.rememberDevice(supported)
  #expect(try store.isKnown(deviceID: supported.id))
  #expect(try store.lastConnectedDeviceID() == supported.id)
}

@Test func storesAndListsRecordingMetadata() throws {
  let fixture = try DatabaseFixture()
  defer { fixture.remove() }
  let store = try Store(path: fixture.databaseURL)
  let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
  let finishedAt = startedAt.addingTimeInterval(10)
  let path = fixture.directory.appendingPathComponent("recording.wav")
  try store.addRecording(
    path: path,
    deviceID: DeviceID(rawValue: "rc003"),
    sampleRate: 48_000,
    sampleCount: 480_000,
    startedAt: startedAt,
    finishedAt: finishedAt
  )

  let recordings = try store.recordings()
  #expect(recordings.count == 1)
  #expect(recordings[0].path == path)
  #expect(recordings[0].deviceID == DeviceID(rawValue: "rc003"))
  #expect(recordings[0].sampleRate == 48_000)
  #expect(recordings[0].sampleCount == 480_000)
  #expect(recordings[0].startedAt == startedAt)
  #expect(recordings[0].finishedAt == finishedAt)
}

private struct DatabaseFixture {
  let directory: URL
  let databaseURL: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    databaseURL = directory.appendingPathComponent("state.db")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }

  func execute(_ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
      throw StorageError.sqlite(code: SQLITE_CANTOPEN, message: "open test database")
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw StorageError.sqlite(
        code: sqlite3_errcode(database),
        message: String(cString: sqlite3_errmsg(database))
      )
    }
  }
}
