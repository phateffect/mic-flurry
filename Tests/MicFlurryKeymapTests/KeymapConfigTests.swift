import Foundation
import MicFlurryDomain
import MicFlurryKeymap
import Testing

@Test func parsesGestureSequencesNoopAndOptions() throws {
  let configuration = try KeymapTOML.parse(
    """
    schema_version = 1
    model = "mi-rc001"

    [options]
    double_click_ms = 350
    hold_ms = 700
    sequence_interval_ms = 25

    [keymap]
    up = "up"
    menu = ["ctrl+b", "n"]

    [keymap.select]
    click = "noop"
    double_click = ["cmd+b", "p", "1"]
    hold = "cmd+x"
    """,
    expectedModel: "mi-rc001"
  )

  #expect(configuration.options.doubleClickMilliseconds == 350)
  #expect(configuration.options.holdMilliseconds == 700)
  #expect(configuration.options.sequenceIntervalMilliseconds == 25)
  #expect(configuration.bindings[.up]?.click == .chords([KeyChord(parsing: "up")!]))
  #expect(configuration.bindings[.select]?.click == .noop)
  #expect(
    configuration.bindings[.select]?.doubleClick
      == .chords([KeyChord(parsing: "cmd+b")!, KeyChord(parsing: "p")!, KeyChord(parsing: "1")!])
  )
}

@Test func serializedConfigurationRoundTrips() throws {
  let configuration = KeymapConfiguration(
    model: "mi-rc003",
    bindings: [
      .select: KeymapBinding(
        click: .noop,
        doubleClick: .chords([KeyChord(parsing: "ctrl+b")!, KeyChord(parsing: "n")!]),
        hold: .chords([KeyChord(parsing: "cmd+x")!])
      ),
      .volumeUp: KeymapBinding(click: .chords([KeyChord(parsing: "a")!])),
    ]
  )
  let text = KeymapTOML.serialize(configuration)
  #expect(try KeymapTOML.parse(text, expectedModel: "mi-rc003") == configuration)
}

@Test func rejectsUnknownDuplicateMismatchedAndUnsafeValues() {
  #expect(throws: KeymapConfigError.invalidModel(expected: "mi-rc001", actual: "mi-rc003")) {
    try KeymapTOML.parse(
      "schema_version = 1\nmodel = \"mi-rc003\"\n",
      expectedModel: "mi-rc001"
    )
  }
  #expect(throws: KeymapConfigError.duplicateField("model")) {
    try KeymapTOML.parse(
      "schema_version = 1\nmodel = \"mi-rc001\"\nmodel = \"mi-rc001\"\n",
      expectedModel: "mi-rc001"
    )
  }
  #expect(throws: KeymapConfigError.invalidAction("mute")) {
    try KeymapTOML.parse(
      "schema_version = 1\nmodel = \"mi-rc001\"\n[keymap]\nmute = \"a\"\n",
      expectedModel: "mi-rc001"
    )
  }
  #expect(throws: KeymapConfigError.invalidOutput("[\"noop\"]")) {
    try KeymapTOML.parse(
      "schema_version = 1\nmodel = \"mi-rc001\"\n[keymap]\nup = [\"noop\"]\n",
      expectedModel: "mi-rc001"
    )
  }
}

@Test func missingFileMigratesLegacyDatabaseMappingOnlyOnce() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = KeymapFileStore(directory: directory)

  let migrated = try store.loadOrMigrate(
    model: "mi-rc001",
    legacyActionChords: ["select": "return", "volume_up": "a"]
  )
  #expect(migrated.bindings[.select]?.click == .chords([KeyChord(parsing: "return")!]))
  #expect(migrated.bindings[.up]?.click == .chords([KeyChord(parsing: "up")!]))
  #expect(migrated.bindings[.back]?.click == .chords([KeyChord(parsing: "escape")!]))
  #expect(migrated.bindings[.volumeDown]?.click == .noop)
  #expect(migrated.bindings.count == KeymapConfiguration.availableActions(model: "mi-rc001").count)
  let generated = try String(contentsOf: store.fileURL(model: "mi-rc001"), encoding: .utf8)
  let orderedNames = [
    "power", "microphone", "up", "down", "left", "right", "select", "back", "home", "menu",
    "volume_down", "volume_up", "tv",
  ]
  let generatedNames = generated.split(separator: "\n").compactMap { line -> String? in
    guard let separator = line.range(of: " = ") else { return nil }
    let name = String(line[..<separator.lowerBound])
    return orderedNames.contains(name) ? name : nil
  }
  #expect(generatedNames == orderedNames)
  #expect(FileManager.default.fileExists(atPath: store.fileURL(model: "mi-rc001").path))

  let existing = try store.loadOrMigrate(
    model: "mi-rc001",
    legacyActionChords: ["select": "escape"]
  )
  #expect(existing == migrated)
}
