@preconcurrency import Darwin
import Foundation
import MicFlurryControl
import MicFlurryDomain
import Testing

@MainActor
@Test func routesVersionedRequestsAndRejectsUnknownMethods() async throws {
  let service = FakeControlService()
  let status = await ControlRouter.route(
    JSONRPCRequest(id: .integer(1), method: ControlMethods.status),
    to: service
  )
  #expect(status?.error == nil)
  #expect(status?.result != nil)

  let unknown = await ControlRouter.route(
    JSONRPCRequest(id: .string("unknown"), method: "v1.no_such_method"),
    to: service
  )
  #expect(unknown?.error?.code == -32_601)
}

@MainActor
@Test func routesConnectionAndSettingsParameters() async throws {
  let service = FakeControlService()
  let deviceID = DeviceID(rawValue: "00000000-0000-0000-0000-000000000004")
  let connect = JSONRPCRequest(
    id: .integer(2),
    method: ControlMethods.connect,
    params: try JSONRPCCodec.value(["device": deviceID])
  )
  let connectResponse = await ControlRouter.route(connect, to: service)
  #expect(connectResponse?.error == nil)
  #expect(service.connectedDevice == deviceID)

  let change = SettingsChange(inputGainDB: 6)
  let settings = JSONRPCRequest(
    id: .integer(3),
    method: ControlMethods.setSettings,
    params: try JSONRPCCodec.value(change)
  )
  let settingsResponse = await ControlRouter.route(settings, to: service)
  #expect(settingsResponse?.error == nil)
  #expect(service.settings.inputGainDB == 6)
}

@MainActor
@Test func hidControlRejectsCallerSuppliedMatchingOverrides() async throws {
  let service = FakeControlService()
  let override = JSONRPCRequest(
    id: .integer(4),
    method: ControlMethods.startHIDCapture,
    params: .object([
      "profile_id": .string("attacker-profile"),
      "vendor_id": .integer(1),
      "product_id": .integer(2),
      "io_registry_path": .string("IOService:/arbitrary"),
    ])
  )

  let response = await ControlRouter.route(override, to: service)
  #expect(response?.error?.code == -32_602)
  #expect(service.hidStartCount == 0)

  let accepted = await ControlRouter.route(
    JSONRPCRequest(id: .integer(5), method: ControlMethods.startHIDCapture, params: .null),
    to: service
  )
  #expect(accepted?.error == nil)
  #expect(service.hidStartCount == 1)
}

@Test func codecUsesNewlineDelimitedSnakeCaseFrames() throws {
  let notification = JSONRPCNotification(
    method: ControlMethods.event,
    params: try JSONRPCCodec.eventValue(Event.audioStarted(rateHz: 16_000))
  )
  let frame = try JSONRPCCodec.line(notification)
  #expect(frame.last == 0x0a)
  let text = String(decoding: frame, as: UTF8.self)
  #expect(text.contains("audio_started"))
  #expect(text.contains("rate_hz"))
  #expect(text.contains("\"type\":\"audio_started\""))
}

@Test func malformedAndOversizedJSONRPCFramesAreRejected() throws {
  for length in 0...512 {
    var bytes = Data([0xff])
    if length > 0 {
      bytes.append(contentsOf: (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 131) })
    }
    #expect(throws: (any Error).self) {
      try JSONRPCCodec.decoder().decode(JSONRPCRequest.self, from: bytes)
    }
  }

  let oversized = JSONRPCRequest(
    id: .integer(1),
    method: String(repeating: "x", count: JSONRPCCodec.maximumFrameBytes)
  )
  #expect(throws: ControlProtocolError.frameTooLarge) {
    try JSONRPCCodec.line(oversized)
  }
}

@MainActor
@Test func unixSocketServesMultipleClientsAndBroadcastsNotifications() async throws {
  guard ProcessInfo.processInfo.environment["MICFLURRY_RUN_SOCKET_TESTS"] == "1" else { return }
  let directory = URL(fileURLWithPath: "/tmp/mf-control-\(UUID().uuidString.prefix(8))")
  defer { try? FileManager.default.removeItem(at: directory) }
  let socketURL = directory.appendingPathComponent("control.sock")
  let service = FakeControlService()
  let server = UnixControlServer(socketURL: socketURL, service: service)
  try server.start()
  defer { server.stop() }

  var directoryInfo = stat()
  #expect(lstat(directory.path, &directoryInfo) == 0)
  #expect(directoryInfo.st_mode & 0o777 == 0o700)
  var socketInfo = stat()
  #expect(lstat(socketURL.path, &socketInfo) == 0)
  #expect(socketInfo.st_mode & 0o777 == 0o600)

  let first = try connectUnixSocket(at: socketURL)
  let second = try connectUnixSocket(at: socketURL)
  defer {
    Darwin.close(first)
    Darwin.close(second)
  }
  let request = try JSONRPCCodec.line(
    JSONRPCRequest(id: .integer(7), method: ControlMethods.status)
  )
  try writeAll(request, to: first)
  try writeAll(request, to: second)

  let firstResponse = try await readLine(from: first)
  let secondResponse = try await readLine(from: second)
  #expect(try JSONRPCCodec.decoder().decode(JSONRPCResponse.self, from: firstResponse).error == nil)
  #expect(
    try JSONRPCCodec.decoder().decode(JSONRPCResponse.self, from: secondResponse).error == nil)

  service.emit(.audioStarted(rateHz: 16_000))
  let firstEvent = try await readLine(from: first)
  let secondEvent = try await readLine(from: second)
  let decodedFirst = try JSONRPCCodec.decoder().decode(JSONRPCNotification.self, from: firstEvent)
  let decodedSecond = try JSONRPCCodec.decoder().decode(JSONRPCNotification.self, from: secondEvent)
  #expect(decodedFirst.method == ControlMethods.event)
  #expect(decodedSecond == decodedFirst)
}

private func connectUnixSocket(at url: URL) throws -> Int32 {
  let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
  do {
    var address = sockaddr_un()
    let bytes = Array(url.path.utf8)
    let headerSize = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path) ?? 2
    guard bytes.count + 1 <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw POSIXError(.ENAMETOOLONG)
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(headerSize + bytes.count + 1)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.copyBytes(from: bytes)
      destination[bytes.count] = 0
    }
    let addressLength = socklen_t(address.sun_len)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, addressLength)
      }
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return descriptor
  } catch {
    Darwin.close(descriptor)
    throw error
  }
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
  try data.withUnsafeBytes { bytes in
    var offset = 0
    while offset < bytes.count {
      let count = Darwin.send(
        descriptor,
        bytes.baseAddress?.advanced(by: offset),
        bytes.count - offset,
        0
      )
      guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      offset += count
    }
  }
}

private func readLine(from descriptor: Int32) async throws -> Data {
  try await Task.detached {
    var result = Data()
    var byte: UInt8 = 0
    while result.count <= JSONRPCCodec.maximumFrameBytes {
      var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      guard Darwin.poll(&descriptorState, 1, 2_000) > 0 else { throw POSIXError(.ETIMEDOUT) }
      let count = Darwin.recv(descriptor, &byte, 1, 0)
      guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNRESET) }
      if byte == 0x0a { return result }
      result.append(byte)
    }
    throw ControlProtocolError.frameTooLarge
  }.value
}

@MainActor
private final class FakeControlService: ControlService {
  let events: AsyncStream<Event>
  private let eventContinuation: AsyncStream<Event>.Continuation
  var status = Status()
  var settings = Settings(recordingDirectory: "/tmp/MicFlurry")
  var connectedDevice: DeviceID?
  var hidStartCount = 0

  init() {
    let stream = AsyncStream.makeStream(of: Event.self)
    events = stream.stream
    eventContinuation = stream.continuation
  }

  func emit(_ event: Event) { eventContinuation.yield(event) }

  func controlStatus() -> Status { status }
  func controlSettings() -> Settings { settings }

  func controlSetSettings(_ change: SettingsChange) throws -> Settings {
    if let gain = change.inputGainDB { settings.inputGainDB = gain }
    return settings
  }

  func controlRefreshDevices() async throws {}
  func controlConnect(to deviceID: DeviceID) async throws { connectedDevice = deviceID }
  func controlRelease() async throws { connectedDevice = nil }
  func controlStartRecording() throws {}
  func controlStopRecording() throws {}
  func controlStartHIDCapture() async throws { hidStartCount += 1 }
  func controlStopHIDCapture() async throws {}
}
