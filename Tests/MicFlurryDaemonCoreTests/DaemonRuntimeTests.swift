import Foundation
import MicFlurryATVV
import MicFlurryAudio
import MicFlurryBluetooth
import MicFlurryControl
import MicFlurryDomain
import MicFlurryHIDClient
import MicFlurryHIDProtocol
import Testing

@testable import MicFlurryDaemonCore

@MainActor
@Test func composesBluetoothATVVAudioAndStorageWithoutHardware() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let bluetooth = FakeBluetooth()
  let sink = MemoryAudioSink()
  let runtime = try DaemonRuntime(
    databaseURL: directory.appendingPathComponent("state.db"),
    bluetooth: bluetooth,
    audioSinkFactory: { _ in sink }
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
}

@MainActor
@Test func releaseCleansLocalStateWhenMicrophoneCloseFails() async throws {
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

  init() {
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

  init() {
    let stream = AsyncStream.makeStream(of: HIDHelperConnectionEvent.self)
    events = stream.stream
    continuation = stream.continuation
  }

  func emit(_ event: HIDHelperConnectionEvent) { continuation.yield(event) }
  func connect() async throws -> HIDHandshake { HIDHandshake(helperBuild: "test") }
  func startCapture(_ request: HIDCaptureRequest) async throws {}
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
