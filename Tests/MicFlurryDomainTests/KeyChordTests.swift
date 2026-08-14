import MicFlurryDomain
import Testing

@Test func keyChordParsesModifiersLettersAndAliases() {
  let chord = KeyChord(parsing: "fn+control")
  #expect(chord?.keys.count == 2)
  #expect(chord?.keys[0].keyCode == 0x3f)
  #expect(chord?.keys[0].modifier == .fn)
  #expect(chord?.keys[1].keyCode == 0x3b)
  #expect(chord?.keys[1].modifier == .control)
  #expect(chord?.text == "fn+control")

  #expect(KeyChord(parsing: "ctrl") == KeyChord(parsing: "control"))
  #expect(KeyChord(parsing: "cmd") == KeyChord(parsing: "command"))
  #expect(KeyChord(parsing: " A ")?.keys.first?.keyCode == 0x00)
  #expect(KeyChord(parsing: "shift+a")?.keys.map(\.name) == ["shift", "a"])
}

@Test func keyChordRejectsEmptyAndUnknownTokens() {
  #expect(KeyChord(parsing: "") == nil)
  #expect(KeyChord(parsing: "not-a-key") == nil)
  #expect(KeyChord(parsing: "fn+not-a-key") == nil)
}

@Test func keyChordValidationRejectsUnknownChordButAllowsDisabling() {
  #expect(throws: SettingsValidationError.invalidKeyChord("not-a-key")) {
    try SettingsValidator.validate(SettingsChange(dictationStartChord: "not-a-key"))
  }
  #expect(throws: Never.self) {
    try SettingsValidator.validate(
      SettingsChange(dictationStartChord: "", actionChords: ["mute": "f5"]))
  }
}
