import MicFlurryDomain
import Testing

@Test func settingsPreserveValidatedRustDefaults() {
  let settings = Settings(recordingDirectory: "/tmp/recordings")
  #expect(settings.injectionDeviceUID == "MicFlurry_2_UID")
  #expect(settings.outputRateHz == 48_000)
  #expect(settings.inputGainDB == 12)
  #expect(settings.autoRecord == false)
}

@Test func mapsKeyboardAndConsumerRemoteUsages() {
  #expect(HIDUsageMapping.keyboardAction(usagePage: 0x07, usage: 0x52) == .up)
  #expect(HIDUsageMapping.keyboardAction(usagePage: 0x07, usage: 0x80) == .volumeUp)
  #expect(HIDUsageMapping.keyboardAction(usagePage: 0x0c, usage: 0xe9) == .volumeUp)
  #expect(HIDUsageMapping.keyboardAction(usagePage: 0xff00, usage: 1) == nil)
}

@Test func validatesSettingsAtTheDomainBoundary() throws {
  #expect(throws: SettingsValidationError.unsupportedOutputRate(22_050)) {
    try SettingsValidator.validate(SettingsChange(outputRateHz: 22_050))
  }
  #expect(throws: SettingsValidationError.invalidInputGain(25)) {
    try SettingsValidator.validate(SettingsChange(inputGainDB: 25))
  }
  try SettingsValidator.validate(
    SettingsChange(outputRateHz: 16_000, inputGainDB: 12, autoRecord: true)
  )
}
