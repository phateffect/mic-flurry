import Foundation
import MicFlurryATVV
import MicFlurryAudio
import MicFlurryBluetooth
import MicFlurryControl
import MicFlurryDomain
import MicFlurryHIDClient
import MicFlurryHIDProtocol
import MicFlurryKeymap
import Testing

@testable import MicFlurryDaemonCore

@MainActor
@Test func composesBluetoothATVVAudioAndStorageWithoutHardware() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let bluetooth = FakeBluetooth()
  let sink = MemoryAudioSink()
  let keyChords = FakeKeyChordPoster()
  let runtime = try DaemonRuntime(
    databaseURL: directory.appendingPathComponent("state.db"),
    bluetooth: bluetooth,
    audioSinkFactory: { _ in sink },
    keyChords: keyChords
  )

  try await runtime.refreshDevices()
  try await runtime.connect(to: FakeBluetooth.deviceID)
  await runtime.handleBluetoothEvent(
    .control(device: FakeBluetooth.deviceID, bytes: [0x04, 0x03, 0x02, 0x2a])
  )
  await runtime.handleBluetoothEvent(
    .control(device: FakeBluetooth.deviceID, bytes: [0x0a, 0x02, 0, 10, 0, 0, 0])
  )
  await runtime.handleBluetoothEvent(
    .audio(device: FakeBluetooth.deviceID, bytes: Array(repeating: 0x17, count: 120))
  )

  #expect(runtime.status.connectedDevice == FakeBluetooth.deviceID)
  #expect(runtime.status.audio.active)
  #expect(runtime.status.audio.sourceRateHz == 16_000)
  #expect(runtime.status.audio.decodedFrames == 240)
  #expect(!sink.samples.isEmpty)
  #expect(bluetooth.commands == [ATVV.getCapabilities])
  #expect(keyChords.log == ["down:fn"])
}

@MainActor
@Test func releaseCleansLocalStateWhenMicrophoneCloseFails() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let bluetooth = FakeBluetooth()
  let keyChords = FakeKeyChordPoster()
  let runtime = try DaemonRuntime(
    databaseURL: directory.appendingPathComponent("state.db"),
    bluetooth: bluetooth,
    audioSinkFactory: { _ in MemoryAudioSink() },
    keyChords: keyChords
  )

  try await runtime.refreshDevices()
  try await runtime.connect(to: FakeBluetooth.deviceID)
  await runtime.handleBluetoothEvent(
    .control(device: FakeBluetooth.deviceID, bytes: [0x04, 0x03, 0x02, 0x2a])
  )
  bluetooth.failWrites = true

  await #expect(throws: FakeBluetooth.Failure.self) {
    try await runtime.release()
  }
  #expect(bluetooth.released)
  #expect(runtime.status.connectedDevice == nil)
  #expect(!runtime.status.audio.active)
  #expect(runtime.status.devices.allSatisfy { !$0.connected })
  #expect(keyChords.log == ["down:fn", "up:fn"])
}

@MainActor
@Test func postsDictationKeysAroundAudioSession() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let bluetooth = FakeBluetooth()
  let keyChords = FakeKeyChordPoster()
  let runtime = try DaemonRuntime(
    databaseURL: directory.appendingPathComponent("state.db"),
    bluetooth: bluetooth,
    audioSinkFactory: { _ in MemoryAudioSink() },
    keyChords: keyChords
  )

  try await runtime.refreshDevices()
  try await runtime.connect(to: FakeBluetooth.deviceID)
  #expect(keyChords.log.isEmpty)

  await runtime.handleBluetoothEvent(
    .control(device: FakeBluetooth.deviceID, bytes: [0x04, 0x03, 0x02, 0x2a])
  )
  #expect(keyChords.log == ["down:fn"])

  await runtime.handleBluetoothEvent(
    .control(device: FakeBluetooth.deviceID, bytes: [0x00, 0x00])
  )
  #expect(keyChords.log == ["down:fn", "up:fn"])
}

@MainActor
@Test func tapModeTapsStartAndEndChords() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let bluetooth = FakeBluetooth()
  let keyChords = FakeKeyChordPoster()
  let runtime = try DaemonRuntime(
    databaseURL: directory.appendingPathComponent("state.db"),
    bluetooth: bluetooth,
    audioSinkFactory: { _ in MemoryAudioSink() },
    keyChords: keyChords
  )
  _ = try runtime.controlSetSettings(
    SettingsChange(dictationStartChord: "fn", dictationEndChord: "shift", dictationMode: "tap")
  )

  try await runtime.refreshDevices()
  try await runtime.connect(to: FakeBluetooth.deviceID)

  await runtime.handleBluetoothEvent(
    .control(device: FakeBluetooth.deviceID, bytes: [0x04, 0x03, 0x02, 0x2a])
  )
  #expect(keyChords.log == ["tap:fn"])

  await runtime.handleBluetoothEvent(
    .control(device: FakeBluetooth.deviceID, bytes: [0x00, 0x00])
  )
  #expect(keyChords.log == ["tap:fn", "tap:shift"])
}

@MainActor
@Test func postsDictationEndWhenBluetoothDisconnectsMidSession() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let bluetooth = FakeBluetooth()
  let keyChords = FakeKeyChordPoster()
  let runtime = try DaemonRuntime(
    databaseURL: directory.appendingPathComponent("state.db"),
    bluetooth: bluetooth,
    audioSinkFactory: { _ in MemoryAudioSink() },
    keyChords: keyChords
  )

  try await runtime.refreshDevices()
  try await runtime.connect(to: FakeBluetooth.deviceID)
  await runtime.handleBluetoothEvent(
    .control(device: FakeBluetooth.deviceID, bytes: [0x04, 0x03, 0x02, 0x2a])
  )
  #expect(keyChords.log == ["down:fn"])

  await runtime.handleBluetoothEvent(.disconnected(FakeBluetooth.deviceID))
  #expect(keyChords.log == ["down:fn", "up:fn"])

  // A disconnect without an active session must not post again.
  await runtime.handleBluetoothEvent(.disconnected(FakeBluetooth.deviceID))
  #expect(keyChords.log == ["down:fn", "up:fn"])
}

@MainActor
@Test func seizedKeysPostConfiguredChords() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let bluetooth = FakeBluetooth()
  let helperTransport = FakeHIDTransport()
  let helperClient = HIDHelperClient(transport: helperTransport)
  let keyChords = FakeKeyChordPoster()
  try KeymapFileStore(directory: directory.appendingPathComponent("keymaps")).write(
    KeymapConfiguration(
      model: "mi-rc003",
      bindings: [
        .volumeUp: KeymapBinding(click: .chords([KeyChord(parsing: "a")!])),
        .volumeDown: KeymapBinding(click: .chords([KeyChord(parsing: "b")!])),
        .select: KeymapBinding(click: .chords([KeyChord(parsing: "return")!])),
      ]
    )
  )
  let runtime = try DaemonRuntime(
    databaseURL: directory.appendingPathComponent("state.db"),
    bluetooth: bluetooth,
    hidClient: helperClient,
    audioSinkFactory: { _ in MemoryAudioSink() },
    keyChords: keyChords
  )
  runtime.start()
  try await runtime.refreshDevices()
  try await runtime.connect(to: FakeBluetooth.deviceID)
  try await runtime.startHIDCapture()

  func emit(_ usage: UInt32, _ value: Int64) {
    helperTransport.emit(
      .capture(
        HIDCaptureEvent(
          sequence: 1,
          monotonicNanoseconds: 0,
          physicalDeviceID: FakeBluetooth.deviceID.rawValue,
          interfaceIndex: 0,
          kind: .value(usagePage: 0x0c, usage: usage, value: value)
        )
      )
    )
  }
  emit(0xe9, 1)
  emit(0xe9, 0)
  await waitUntil { keyChords.log.count == 1 }
  emit(0xea, 1)
  emit(0xea, 0)
  await waitUntil { keyChords.log.count == 2 }
  emit(0x41, 1)
  emit(0x41, 0)
  await waitUntil { keyChords.log.count == 3 }
  emit(0xe9, 0)  // an unmatched release must not post again
  try? await Task.sleep(for: .milliseconds(20))
  #expect(keyChords.log == ["tap:a", "tap:b", "tap:return"])
  await runtime.stop()
}

@MainActor
@Test func rc001UsesStructuredFingerprintAndDedicatedHIDProfile() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let bluetooth = FakeBluetooth(modelNumber: "RC001")
  let helperTransport = FakeHIDTransport()
  let runtime = try DaemonRuntime(
    databaseURL: directory.appendingPathComponent("state.db"),
    bluetooth: bluetooth,
    hidClient: HIDHelperClient(transport: helperTransport),
    audioSinkFactory: { _ in MemoryAudioSink() }
  )

  try await runtime.refreshDevices()
  try await runtime.connect(to: FakeBluetooth.deviceID)
  try await runtime.startHIDCapture()

  #expect(runtime.status.devices.first?.support.model == "mi-rc001")
  #expect(helperTransport.requests.map(\.profileID) == ["rc001-v1"])
  await runtime.stop()
}

@MainActor
@Test func keymapRecognizesDoubleClickHoldNoopAndSerializedChordSequences() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let keymapDirectory = directory.appendingPathComponent("keymaps")
  try KeymapFileStore(directory: keymapDirectory).write(
    KeymapConfiguration(
      model: "mi-rc003",
      options: KeymapOptions(
        doubleClickMilliseconds: 100,
        holdMilliseconds: 250,
        sequenceIntervalMilliseconds: 10
      ),
      bindings: [
        .select: KeymapBinding(
          click: .noop,
          doubleClick: .chords([
            KeyChord(parsing: "cmd+b")!, KeyChord(parsing: "p")!, KeyChord(parsing: "1")!,
          ]),
          hold: .chords([KeyChord(parsing: "cmd+x")!])
        )
      ]
    )
  )
  let bluetooth = FakeBluetooth()
  let helperTransport = FakeHIDTransport()
  let keyChords = FakeKeyChordPoster()
  let runtime = try DaemonRuntime(
    databaseURL: directory.appendingPathComponent("state.db"),
    keymapDirectory: keymapDirectory,
    bluetooth: bluetooth,
    hidClient: HIDHelperClient(transport: helperTransport),
    audioSinkFactory: { _ in MemoryAudioSink() },
    keyChords: keyChords
  )
  runtime.start()
  try await runtime.refreshDevices()
  try await runtime.connect(to: FakeBluetooth.deviceID)
  try await runtime.startHIDCapture()

  func select(_ pressed: Bool) {
    helperTransport.emit(
      .capture(
        HIDCaptureEvent(
          sequence: 1,
          monotonicNanoseconds: 0,
          physicalDeviceID: FakeBluetooth.deviceID.rawValue,
          interfaceIndex: 0,
          kind: .value(usagePage: 0x0c, usage: 0x41, value: pressed ? 1 : 0)
        )
      )
    )
  }

  select(true)
  select(false)
  try? await Task.sleep(for: .milliseconds(20))
  select(true)
  select(false)
  await waitUntil { keyChords.log.count == 3 }
  #expect(keyChords.log == ["tap:command+b", "tap:p", "tap:1"])

  select(true)
  try? await Task.sleep(for: .milliseconds(300))
  select(false)
  await waitUntil { keyChords.log.count == 4 }
  #expect(keyChords.log.last == "tap:command+x")

  select(true)
  select(false)
  try? await Task.sleep(for: .milliseconds(130))
  #expect(keyChords.log.count == 4)
  await runtime.stop()
}

@MainActor
@Test func controlSettingsReconfigureAudioAtomicallyAndPersist() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let databaseURL = directory.appendingPathComponent("state.db")
  let bluetooth = FakeBluetooth()
  var openedRates: [UInt32] = []
  let runtime = try DaemonRuntime(
    databaseURL: databaseURL,
    bluetooth: bluetooth,
    audioSinkFactory: { settings in
      openedRates.append(settings.outputRateHz)
      return MemoryAudioSink()
    }
  )

  let gainOnly = try runtime.controlSetSettings(SettingsChange(inputGainDB: 6))
  #expect(gainOnly.inputGainDB == 6)
  #expect(openedRates == [48_000])

  let reconfigured = try runtime.controlSetSettings(SettingsChange(outputRateHz: 16_000))
  #expect(reconfigured.outputRateHz == 16_000)
  #expect(runtime.status.audio.outputRateHz == 16_000)
  #expect(openedRates == [48_000, 16_000])

  let restored = try DaemonRuntime(
    databaseURL: databaseURL,
    bluetooth: FakeBluetooth(),
    audioSinkFactory: { _ in MemoryAudioSink() }
  )
  #expect(restored.settings.inputGainDB == 6)
  #expect(restored.settings.outputRateHz == 16_000)
  #expect(throws: DaemonRuntimeError.keymapManagedByConfigurationFile) {
    try runtime.controlSetSettings(SettingsChange(actionChords: ["select": "return"]))
  }
}

@MainActor
@Test func reloadKeymapAtomicallyReplacesTheAttachedModelMapping() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let keymapDirectory = directory.appendingPathComponent("keymaps")
  let keymapStore = KeymapFileStore(directory: keymapDirectory)
  try keymapStore.write(
    KeymapConfiguration(
      model: "mi-rc003",
      bindings: [.volumeUp: KeymapBinding(click: .chords([KeyChord(parsing: "a")!]))]
    )
  )
  let helperTransport = FakeHIDTransport()
  let keyChords = FakeKeyChordPoster()
  let runtime = try DaemonRuntime(
    databaseURL: directory.appendingPathComponent("state.db"),
    keymapDirectory: keymapDirectory,
    bluetooth: FakeBluetooth(),
    hidClient: HIDHelperClient(transport: helperTransport),
    audioSinkFactory: { _ in MemoryAudioSink() },
    keyChords: keyChords
  )
  runtime.start()
  try await runtime.refreshDevices()
  try await runtime.connect(to: FakeBluetooth.deviceID)
  try await runtime.startHIDCapture()

  try keymapStore.write(
    KeymapConfiguration(
      model: "mi-rc003",
      bindings: [.volumeUp: KeymapBinding(click: .chords([KeyChord(parsing: "b")!]))]
    )
  )
  try runtime.reloadKeymap()
  for value: Int64 in [1, 0] {
    helperTransport.emit(
      .capture(
        HIDCaptureEvent(
          sequence: 1,
          monotonicNanoseconds: 0,
          physicalDeviceID: FakeBluetooth.deviceID.rawValue,
          interfaceIndex: 0,
          kind: .value(usagePage: 0x0c, usage: 0xe9, value: value)
        )
      )
    )
  }
  await waitUntil { keyChords.log.count == 1 }
  #expect(keyChords.log == ["tap:b"])
  await runtime.stop()
}

@MainActor
@Test func helperInterruptionDoesNotDisconnectBluetoothOrAudioRuntime() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let bluetooth = FakeBluetooth()
  let helperTransport = FakeHIDTransport()
  let helperClient = HIDHelperClient(transport: helperTransport)
  let runtime = try DaemonRuntime(
    databaseURL: directory.appendingPathComponent("state.db"),
    bluetooth: bluetooth,
    hidClient: helperClient,
    audioSinkFactory: { _ in MemoryAudioSink() }
  )
  runtime.start()
  try await runtime.refreshDevices()
  try await runtime.connect(to: FakeBluetooth.deviceID)
  try await runtime.startHIDCapture()
  #expect(runtime.status.hid.active)

  helperTransport.emit(
    .capture(
      HIDCaptureEvent(
        sequence: 1,
        monotonicNanoseconds: 10,
        physicalDeviceID: FakeBluetooth.deviceID.rawValue,
        interfaceIndex: 0,
        kind: .value(usagePage: 0x0c, usage: 0xe9, value: 1)
      )
    )
  )
  await waitUntil { !runtime.status.hid.recentInputs.isEmpty }
  #expect(runtime.status.hid.recentInputs.last?.mappedAction == .volumeUp)

  helperTransport.emit(.interrupted)
  await waitUntil { !runtime.status.hid.active }
  #expect(runtime.status.connectedDevice == FakeBluetooth.deviceID)
  #expect(!bluetooth.released)
  await runtime.stop()
}

@MainActor
@Test func unexpectedHIDRemovalAutomaticallyReseizesWhileExplicitStopDoesNot() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let bluetooth = FakeBluetooth()
  let helperTransport = FakeHIDTransport()
  let runtime = try DaemonRuntime(
    databaseURL: directory.appendingPathComponent("state.db"),
    bluetooth: bluetooth,
    hidClient: HIDHelperClient(transport: helperTransport),
    audioSinkFactory: { _ in MemoryAudioSink() }
  )
  runtime.start()
  try await runtime.refreshDevices()
  try await runtime.connect(to: FakeBluetooth.deviceID)
  try await runtime.startHIDCapture()
  #expect(helperTransport.requests.count == 1)

  helperTransport.emit(.stopped("device_removed:old-interface"))
  await waitUntil { !runtime.status.hid.active }
  await runtime.recoverHIDCaptureIfNeeded()
  #expect(runtime.status.hid.active)
  #expect(helperTransport.requests.count == 2)

  try await runtime.stopHIDCapture()
  await runtime.recoverHIDCaptureIfNeeded()
  #expect(!runtime.status.hid.active)
  #expect(helperTransport.requests.count == 2)
  await runtime.stop()
}

@MainActor
@Test func repeatedConnectIsIdempotentAndExplicitHIDStopReturnsToMonitorMode() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let bluetooth = FakeBluetooth()
  let helperTransport = FakeHIDTransport()
  let helperClient = HIDHelperClient(transport: helperTransport)
  let runtime = try DaemonRuntime(
    databaseURL: directory.appendingPathComponent("state.db"),
    bluetooth: bluetooth,
    hidClient: helperClient,
    audioSinkFactory: { _ in MemoryAudioSink() }
  )
  runtime.start()
  try await runtime.refreshDevices()
  try await runtime.connect(to: FakeBluetooth.deviceID)
  try await runtime.connect(to: FakeBluetooth.deviceID)
  #expect(bluetooth.attachCount == 1)

  try await runtime.startHIDCapture()
  #expect(runtime.status.hid.mode == .seize)
  try await runtime.stopHIDCapture()
  #expect(!runtime.status.hid.active)
  #expect(runtime.status.hid.mode == .monitor)
  #expect(runtime.status.hid.lastError == nil)
  await runtime.stop()
}

@MainActor
@Test func staleBluetoothAttachmentRecoversKnownDeviceButExplicitReleaseStaysReleased() async throws
{
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let bluetooth = FakeBluetooth()
  let runtime = try DaemonRuntime(
    databaseURL: directory.appendingPathComponent("state.db"),
    bluetooth: bluetooth,
    audioSinkFactory: { _ in MemoryAudioSink() }
  )

  try await runtime.refreshDevices()
  try await runtime.connect(to: FakeBluetooth.deviceID)
  #expect(bluetooth.attachCount == 1)
  bluetooth.attachmentConnected = false

  await runtime.recoverBluetoothAttachmentIfNeeded()
  #expect(bluetooth.releaseCount == 1)
  #expect(bluetooth.attachCount == 2)
  #expect(runtime.status.connectedDevice == FakeBluetooth.deviceID)
  #expect(runtime.status.lastError == nil)

  try await runtime.release()
  #expect(runtime.status.connectedDevice == nil)
  let attachCountAfterRelease = bluetooth.attachCount
  await runtime.recoverBluetoothAttachmentIfNeeded()
  #expect(bluetooth.attachCount == attachCountAfterRelease)
}

@MainActor
private final class FakeBluetooth: BluetoothTransport {
  enum Failure: Error {
    case injected
  }

  static let deviceID = DeviceID(rawValue: "00000000-0000-0000-0000-000000000003")

  let events: AsyncStream<BluetoothEvent>
  private let continuation: AsyncStream<BluetoothEvent>.Continuation
  var commands: [[UInt8]] = []
  var failWrites = false
  var released = false
  var attachCount = 0
  var releaseCount = 0
  var attachmentConnected = false
  let modelNumber: String

  init(modelNumber: String = "RC003") {
    self.modelNumber = modelNumber
    let stream = AsyncStream.makeStream(of: BluetoothEvent.self)
    events = stream.stream
    continuation = stream.continuation
  }

  func connectedATVVDevices() async throws -> [Device] {
    [
      Device(
        id: Self.deviceID,
        name: "RC003",
        connected: true,
        supportsATVV: true,
        support: .supported(model: "小米语音遥控器")
      )
    ]
  }

  func attachedDeviceIsConnected() -> Bool { attachmentConnected }

  func attach(to deviceID: DeviceID) async throws -> DeviceInfo {
    attachCount += 1
    attachmentConnected = true
    commands.append(ATVV.getCapabilities)
    var information = DeviceInfo()
    information.physicalDeviceID = deviceID.rawValue
    information.hidManufacturer = "MIOM"
    information.hidVendorID = 0x2717
    information.hidProductID = 0x32b8
    information.manufacturerName = "MIOM"
    information.modelNumber = modelNumber
    information.hardwareRevision = "V2.0"
    return information
  }

  func writeCommand(_ bytes: [UInt8]) throws {
    if failWrites { throw Failure.injected }
    commands.append(bytes)
  }

  func release() async throws {
    released = true
    releaseCount += 1
    attachmentConnected = false
  }
}

@MainActor
private final class FakeHIDTransport: HIDHelperTransport {
  let events: AsyncStream<HIDHelperConnectionEvent>
  private let continuation: AsyncStream<HIDHelperConnectionEvent>.Continuation
  var requests: [HIDCaptureRequest] = []

  init() {
    let stream = AsyncStream.makeStream(of: HIDHelperConnectionEvent.self)
    events = stream.stream
    continuation = stream.continuation
  }

  func emit(_ event: HIDHelperConnectionEvent) { continuation.yield(event) }
  func connect() async throws -> HIDHandshake { HIDHandshake(helperBuild: "test") }
  func startCapture(_ request: HIDCaptureRequest) async throws { requests.append(request) }
  func heartbeat() async throws {}
  func stopCapture() async throws {}
  func invalidate() {}
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
  for _ in 0..<500 {
    if condition() { return }
    try? await Task.sleep(for: .milliseconds(1))
  }
}

private final class MemoryAudioSink: AudioSink, @unchecked Sendable {
  var samples: [Float] = []
  var droppedSamples: UInt64 = 0

  func push(_ samples: [Float]) -> Int {
    self.samples.append(contentsOf: samples)
    return samples.count
  }
}

private final class FakeKeyChordPoster: KeyChordPosting, @unchecked Sendable {
  var log: [String] = []
  var succeed = true

  func postChord(_ chord: KeyChord) -> Bool {
    log.append("tap:\(chord.text)")
    return succeed
  }

  func holdChord(_ chord: KeyChord, down: Bool) -> Bool {
    log.append(down ? "down:\(chord.text)" : "up:\(chord.text)")
    return succeed
  }
}
