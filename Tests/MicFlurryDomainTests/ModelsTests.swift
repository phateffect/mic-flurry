import MicFlurryDomain
import Testing

@Test func settingsPreserveValidatedDefaults() {
  let settings = Settings(recordingDirectory: "/tmp/recordings")
  #expect(settings.injectionDeviceUID == "MicFlurry_2_UID")
  #expect(settings.outputRateHz == 48_000)
  #expect(settings.inputGainDB == 12)
  #expect(settings.autoRecord == false)
}

@Test func mapsKeyboardAndConsumerRemoteUsages() {
  #expect(HIDUsageMapping.keyboardAction(usagePage: 0x07, usage: 0x52) == .up)
  #expect(HIDUsageMapping.keyboardAction(usagePage: 0x07, usage: 0x80) == .volumeUp)
  #expect(HIDUsageMapping.keyboardAction(usagePage: 0x07, usage: 0x35) == .tv)
  #expect(HIDUsageMapping.keyboardAction(usagePage: 0x07, usage: 0x3e) == .microphone)
  #expect(HIDUsageMapping.keyboardAction(usagePage: 0x07, usage: 0x65) == .menu)
  #expect(HIDUsageMapping.keyboardAction(usagePage: 0x07, usage: 0x66) == .power)
  #expect(HIDUsageMapping.keyboardAction(usagePage: 0x0c, usage: 0xe9) == .volumeUp)
  #expect(HIDUsageMapping.keyboardAction(usagePage: 0xff00, usage: 1) == nil)
}

@Test func structuredRemoteFingerprintsResolveModelsWithoutDisplayNames() {
  let hid = RemoteHIDFingerprint(manufacturer: "MIOM", vendorID: 0x2717, productID: 0x32b8)
  let rc001 = RemoteCatalog.profile(
    hid: hid,
    dis: RemoteDISFingerprint(
      manufacturer: "MIOM",
      modelNumber: "RC001",
      hardwareRevision: "V2.0"
    )
  )
  let rc003 = RemoteCatalog.profile(
    hid: hid,
    dis: RemoteDISFingerprint(
      manufacturer: "MIOM",
      modelNumber: "RC003",
      hardwareRevision: "V2.0"
    )
  )

  #expect(rc001?.model == "mi-rc001")
  #expect(rc001?.hidProfileID == "rc001-v1")
  #expect(rc003?.model == "mi-rc003")
  #expect(
    RemoteCatalog.profile(
      hid: hid,
      dis: RemoteDISFingerprint(
        manufacturer: "MIOM",
        modelNumber: "RC001",
        hardwareRevision: "unknown"
      )
    ) == nil
  )
}

@Test func xiaomiRemoteModelsExposeTheirPhysicalKeymapActions() {
  let actions = RemoteCatalog.keymapActions(model: "mi-rc001")
  #expect(
    actions == [
      .power, .microphone, .up, .down, .left, .right, .select, .back, .home, .menu,
      .volumeDown, .volumeUp, .tv,
    ])
  #expect(!actions!.contains(.mute))
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
