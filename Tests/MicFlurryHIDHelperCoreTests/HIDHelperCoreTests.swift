import Foundation
import MicFlurryHIDProtocol
import Testing

@testable import MicFlurryHIDHelperCore

@Test func bundledCatalogAllowsOnlyRegisteredXiaomiRemoteProfiles() throws {
  let catalog = try TrustedHIDDeviceCatalog.bundled()
  let rc001 = try catalog.validatedProfile(id: "rc001-v1")
  #expect(rc001.product == nil)
  let profile = try catalog.validatedProfile(id: "rc003-v1")
  #expect(profile.manufacturer == "MIOM")
  #expect(profile.vendorID == 0x2717)
  #expect(profile.productID == 0x32b8)
  #expect(profile.capturePolicy == .allInterfacesAllInputs)
  #expect(catalog.profiles.count == 2)
  #expect(throws: HIDCatalogError.unknownProfile("arbitrary")) {
    try catalog.validatedProfile(id: "arbitrary")
  }
}

@Test func catalogRejectsDuplicatesAndUnsafeBounds() {
  let profile = testProfile()
  #expect(throws: HIDCatalogError.duplicateProfileID("rc003-v1")) {
    try HIDDeviceCatalog(schemaVersion: 1, profiles: [profile, profile]).validate()
  }
  var oversized = profile
  oversized.maximumReportBytes = MicFlurryHIDProtocolVersion.maximumReportBytes + 1
  #expect(
    throws: HIDCatalogError.invalidMaximumReportBytes(oversized.maximumReportBytes)
  ) {
    try HIDDeviceCatalog(schemaVersion: 1, profiles: [oversized]).validate()
  }
}

@Test func protocolRejectsUnboundedAndUnversionedPayloads() throws {
  #expect(throws: HIDProtocolError.unsupportedVersion(2)) {
    try HIDCaptureRequest(protocolVersion: 2, profileID: "rc003-v1").validate()
  }
  let event = HIDCaptureEvent(
    sequence: 1,
    monotonicNanoseconds: 42,
    physicalDeviceID: "remote",
    interfaceIndex: 0,
    kind: .rawReport(reportType: 0, reportID: 1, bytes: Data(repeating: 0, count: 1_025))
  )
  #expect(throws: HIDProtocolError.invalidReportSize(1_025)) {
    try event.validate()
  }
  #expect(throws: HIDProtocolError.payloadTooLarge(65_537)) {
    try HIDProtocolCodec.decode(HIDCaptureRequest.self, from: Data(repeating: 0, count: 65_537))
  }
}

@Test func malformedPrivateXPCPayloadsAndManifestBoundsAreRejected() {
  for length in 0...512 {
    var bytes = Data([0xff])
    if length > 0 {
      bytes.append(contentsOf: (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 73) })
    }
    #expect(throws: (any Error).self) {
      try HIDProtocolCodec.decode(HIDCaptureRequest.self, from: bytes)
    }
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(HIDDeviceCatalog.self, from: bytes)
    }
  }

  for maximumInterfaces in [0, 33, Int.max] {
    var profile = testProfile()
    profile.maximumInterfaces = maximumInterfaces
    #expect(throws: HIDCatalogError.invalidMaximumInterfaces(maximumInterfaces)) {
      try HIDDeviceCatalog(schemaVersion: 1, profiles: [profile]).validate()
    }
  }
  for maximumReportBytes in [0, MicFlurryHIDProtocolVersion.maximumReportBytes + 1, Int.max] {
    var profile = testProfile()
    profile.maximumReportBytes = maximumReportBytes
    #expect(throws: HIDCatalogError.invalidMaximumReportBytes(maximumReportBytes)) {
      try HIDDeviceCatalog(schemaVersion: 1, profiles: [profile]).validate()
    }
  }
}

@Test func productionSecurityRequirementBindsIdentifierAnchorAndTeam() throws {
  let policy = try HIDHelperSecurityPolicy(teamID: "ABCDE12345")
  #expect(policy.daemonCodeSigningRequirement.contains("anchor apple generic"))
  #expect(
    policy.daemonCodeSigningRequirement.contains("io.phateffect.MicFlurry.daemon")
  )
  #expect(policy.daemonCodeSigningRequirement.contains("ABCDE12345"))
  #expect(policy.accepts(effectiveUID: 501, consoleUID: 501))
  #expect(!policy.accepts(effectiveUID: 0, consoleUID: 0))
  #expect(!policy.accepts(effectiveUID: 502, consoleUID: 501))
  #expect(!policy.accepts(effectiveUID: 501, consoleUID: nil))
  #expect(throws: HIDHelperSecurityError.invalidTeamID) {
    try HIDHelperSecurityPolicy(teamID: "unsafe")
  }
}

#if MICFLURRY_PRIVATE_DISTRIBUTION
  @Test func privateHelperRequirementPinsTheDaemonIdentifierAndCDHash() throws {
    let hash = "0123456789abcdef0123456789abcdef01234567"
    let policy = try HIDHelperSecurityPolicy.privateAdHoc(daemonCDHash: hash)
    #expect(
      policy.daemonCodeSigningRequirement
        == "identifier \"io.phateffect.MicFlurry.daemon\" and cdhash H\"\(hash)\""
    )
    #expect(throws: HIDHelperSecurityError.invalidCDHash) {
      try HIDHelperSecurityPolicy.privateAdHoc(daemonCDHash: "unsafe")
    }
  }
#endif

@Test func interfaceSelectionRequiresAnExplicitPhysicalDeviceWhenAmbiguous() throws {
  let interfaces = [descriptor(id: "a1", physical: "a"), descriptor(id: "b1", physical: "b")]
  #expect(throws: HIDCaptureError.physicalDeviceIDRequired) {
    try HIDInterfaceSelection.select(interfaces, profile: testProfile(), physicalDeviceID: nil)
  }
  let selected = try HIDInterfaceSelection.select(
    interfaces,
    profile: testProfile(),
    physicalDeviceID: "b"
  )
  #expect(selected.map(\.identifier) == ["b1"])
}

@Test func interfaceSelectionRejectsUnregisteredHardwareAndUnknownPhysicalDevice() {
  let wrongManufacturer = descriptor(
    id: "wrong-manufacturer", physical: "remote", manufacturer: "Other"
  )
  let wrongVendor = descriptor(id: "wrong-vendor", physical: "remote", vendorID: 0x0001)
  let wrongProduct = descriptor(id: "wrong-product", physical: "remote", productID: 0x0002)

  #expect(throws: HIDCaptureError.noMatchingDevice) {
    try HIDInterfaceSelection.select(
      [wrongManufacturer, wrongVendor, wrongProduct],
      profile: testProfile(),
      physicalDeviceID: nil
    )
  }
  #expect(throws: HIDCaptureError.physicalDeviceNotFound("attacker-selected-device")) {
    try HIDInterfaceSelection.select(
      [descriptor(id: "registered", physical: "real-device")],
      profile: testProfile(),
      physicalDeviceID: "attacker-selected-device"
    )
  }
}

@MainActor
@Test func leaseRejectsUnknownProfileBeforeHardwareEnumeration() throws {
  let backend = FakeBackend()
  let controller = try HIDLeaseController(
    catalog: HIDDeviceCatalog(schemaVersion: 1, profiles: [testProfile()]),
    backend: backend
  )

  #expect(throws: HIDCatalogError.unknownProfile("attacker-profile")) {
    try controller.start(
      owner: HIDLeaseOwner(),
      request: HIDCaptureRequest(profileID: "attacker-profile")
    )
  }
  #expect(backend.startCount == 0)
  #expect(!controller.active)
}

@MainActor
@Test func atomicCaptureRollsBackEveryOpenedInterfaceAfterCallbackFailure() {
  let log = OperationLog()
  let first = FakeInterface(identifier: "1", log: log)
  let second = FakeInterface(identifier: "2", log: log, failCallbacks: true)
  let capture = AtomicHIDCapture()

  #expect(throws: FakeFailure.injected) {
    try capture.start(interfaces: [first, second])
  }
  #expect(capture.activeInterfaceCount == 0)
  #expect(
    log.entries == [
      "open:1", "open:2", "callbacks:1:0", "callbacks:2:1",
      "uninstall:2", "close:2", "uninstall:1", "close:1",
    ]
  )
}

@MainActor
@Test func leaseHasOneOwnerAndReleasesOnTimeoutAndInvalidation() throws {
  let backend = FakeBackend()
  let clock = TestClock(now: 100)
  let controller = try HIDLeaseController(
    catalog: HIDDeviceCatalog(schemaVersion: 1, profiles: [testProfile()]),
    backend: backend,
    heartbeatTimeoutNanoseconds: 10,
    now: { clock.now }
  )
  let owner = HIDLeaseOwner()
  let other = HIDLeaseOwner()
  try controller.start(owner: owner, request: HIDCaptureRequest(profileID: "rc003-v1"))
  #expect(controller.active)
  #expect(throws: HIDCaptureError.captureOwnedByAnotherClient) {
    try controller.start(owner: other, request: HIDCaptureRequest(profileID: "rc003-v1"))
  }
  clock.now = 105
  try controller.heartbeat(owner: owner)
  clock.now = 114
  #expect(!controller.expireIfNeeded())
  clock.now = 115
  #expect(controller.expireIfNeeded())
  #expect(backend.stopCount == 1)

  try controller.start(owner: owner, request: HIDCaptureRequest(profileID: "rc003-v1"))
  controller.connectionInvalidated(owner: other)
  #expect(controller.active)
  controller.connectionInvalidated(owner: owner)
  #expect(!controller.active)
  #expect(backend.stopCount == 2)
}

@MainActor
@Test func failedCaptureStartupNeverCreatesALease() throws {
  let backend = FakeBackend()
  backend.failStart = true
  let controller = try HIDLeaseController(
    catalog: HIDDeviceCatalog(schemaVersion: 1, profiles: [testProfile()]),
    backend: backend
  )
  #expect(throws: FakeFailure.injected) {
    try controller.start(
      owner: HIDLeaseOwner(),
      request: HIDCaptureRequest(profileID: "rc003-v1")
    )
  }
  #expect(!controller.active)
  #expect(backend.stopCount == 0)
}

@MainActor
@Test func unexpectedBackendStopClearsLeaseWithoutStoppingBackendTwice() throws {
  let backend = FakeBackend()
  let controller = try HIDLeaseController(
    catalog: HIDDeviceCatalog(schemaVersion: 1, profiles: [testProfile()]),
    backend: backend
  )
  try controller.start(
    owner: HIDLeaseOwner(),
    request: HIDCaptureRequest(profileID: "rc003-v1")
  )

  #expect(controller.backendStoppedUnexpectedly())
  #expect(!controller.active)
  #expect(backend.stopCount == 0)
  #expect(!controller.backendStoppedUnexpectedly())
}

@MainActor
@Test func connectionInvalidatedDuringCaptureStartupRollsBackBeforeCreatingLease() throws {
  let backend = FakeBackend()
  let validity = HIDConnectionValidity()
  backend.onStart = { validity.invalidate() }
  let controller = try HIDLeaseController(
    catalog: HIDDeviceCatalog(schemaVersion: 1, profiles: [testProfile()]),
    backend: backend
  )

  #expect(throws: HIDLeaseError.ownerInvalidatedDuringStart) {
    try controller.start(
      owner: HIDLeaseOwner(),
      request: HIDCaptureRequest(profileID: "rc003-v1"),
      isOwnerValid: { validity.isValid }
    )
  }
  #expect(!controller.active)
  #expect(backend.stopCount == 1)
}

private func testProfile() -> HIDDeviceProfile {
  HIDDeviceProfile(
    id: "rc003-v1",
    manufacturer: "MIOM",
    vendorID: 0x2717,
    productID: 0x32b8,
    maximumInterfaces: 8,
    maximumReportBytes: 1_024,
    capturePolicy: .allInterfacesAllInputs
  )
}

private func descriptor(id: String, physical: String) -> HIDInterfaceDescriptor {
  descriptor(
    id: id,
    physical: physical,
    manufacturer: "MIOM",
    vendorID: 0x2717,
    productID: 0x32b8
  )
}

private func descriptor(
  id: String,
  physical: String,
  manufacturer: String = "MIOM",
  vendorID: UInt32 = 0x2717,
  productID: UInt32 = 0x32b8
) -> HIDInterfaceDescriptor {
  HIDInterfaceDescriptor(
    identifier: id,
    physicalDeviceID: physical,
    manufacturer: manufacturer,
    vendorID: vendorID,
    productID: productID,
    product: nil,
    transport: nil,
    maximumInputReportBytes: 64
  )
}

@MainActor
private final class FakeBackend: HIDCaptureBackend {
  var startCount = 0
  var stopCount = 0
  var failStart = false
  var onStart: (() -> Void)?

  func start(profile: HIDDeviceProfile, physicalDeviceID: String?) throws {
    startCount += 1
    if failStart { throw FakeFailure.injected }
    onStart?()
  }
  func stop() { stopCount += 1 }
}

@MainActor
private final class TestClock {
  var now: UInt64

  init(now: UInt64) {
    self.now = now
  }
}

private final class OperationLog {
  var entries: [String] = []
}

private enum FakeFailure: Error {
  case injected
}

@MainActor
private final class FakeInterface: HIDCaptureInterface {
  let descriptor: HIDInterfaceDescriptor
  let log: OperationLog
  let failCallbacks: Bool

  init(identifier: String, log: OperationLog, failCallbacks: Bool = false) {
    descriptor = HIDInterfaceDescriptor(
      identifier: identifier,
      physicalDeviceID: "remote",
      manufacturer: "MIOM",
      vendorID: 0x2717,
      productID: 0x32b8,
      product: nil,
      transport: nil,
      maximumInputReportBytes: 64
    )
    self.log = log
    self.failCallbacks = failCallbacks
  }

  func openSeized() throws { log.entries.append("open:\(descriptor.identifier)") }

  func installCallbacks(interfaceIndex: UInt16) throws {
    log.entries.append("callbacks:\(descriptor.identifier):\(interfaceIndex)")
    if failCallbacks { throw FakeFailure.injected }
  }

  func uninstallCallbacks() { log.entries.append("uninstall:\(descriptor.identifier)") }
  func close() { log.entries.append("close:\(descriptor.identifier)") }
}
