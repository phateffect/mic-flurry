import Foundation
import MicFlurryHIDClient
import MicFlurryHIDProtocol
import Testing

@Test func daemonRequirementAuthenticatesTheExpectedHelper() throws {
  let policy = try HIDDaemonSecurityPolicy(teamID: "ABCDE12345")
  #expect(policy.helperCodeSigningRequirement.contains("anchor apple generic"))
  #expect(policy.helperCodeSigningRequirement.contains("io.phateffect.MicFlurry.hid-helper"))
  #expect(policy.helperCodeSigningRequirement.contains("ABCDE12345"))
  #expect(throws: HIDHelperClientError.invalidTeamID) {
    try HIDDaemonSecurityPolicy(teamID: "unsafe")
  }
}

#if MICFLURRY_PRIVATE_DISTRIBUTION
  @Test func privateDaemonRequirementPinsTheHelperIdentifierAndCDHash() throws {
    let hash = "0123456789abcdef0123456789abcdef01234567"
    let policy = try HIDDaemonSecurityPolicy.privateAdHoc(helperCDHash: hash)
    #expect(
      policy.helperCodeSigningRequirement
        == "identifier \"io.phateffect.MicFlurry.hid-helper\" and cdhash H\"\(hash)\""
    )
    #expect(throws: HIDHelperClientError.invalidCDHash) {
      try HIDDaemonSecurityPolicy.privateAdHoc(helperCDHash: "unsafe")
    }
  }
#endif

@MainActor
@Test func clientNegotiatesStartsHeartbeatsAndStopsWithoutOwningOtherRuntime() async throws {
  let transport = FakeTransport()
  let client = HIDHelperClient(
    transport: transport,
    heartbeatInterval: .milliseconds(1)
  )
  try await client.startCapture(profileID: "rc003-v1", physicalDeviceID: "remote")
  #expect(client.connected)
  #expect(client.captureActive)
  #expect(
    transport.requests == [HIDCaptureRequest(profileID: "rc003-v1", physicalDeviceID: "remote")])

  await waitUntil { transport.heartbeatCount > 0 }
  #expect(transport.heartbeatCount > 0)
  try await client.stopCapture()
  #expect(!client.captureActive)
  #expect(transport.stopCount == 1)
  await client.shutdown()
  #expect(transport.invalidated)
}

@MainActor
@Test func interruptionClearsOnlyHelperStateAndAllowsReconnect() async throws {
  let transport = FakeTransport()
  let client = HIDHelperClient(transport: transport)
  try await client.startCapture(profileID: "rc003-v1", physicalDeviceID: nil)
  transport.emit(.interrupted)
  await waitUntil { !client.connected }
  #expect(!client.connected)
  #expect(!client.captureActive)

  try await client.connect()
  #expect(client.connected)
  #expect(transport.connectCount == 2)
  await client.shutdown()
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
  for _ in 0..<500 {
    if condition() { return }
    try? await Task.sleep(for: .milliseconds(1))
  }
}

@MainActor
private final class FakeTransport: HIDHelperTransport {
  let events: AsyncStream<HIDHelperConnectionEvent>
  let continuation: AsyncStream<HIDHelperConnectionEvent>.Continuation
  var connectCount = 0
  var requests: [HIDCaptureRequest] = []
  var heartbeatCount = 0
  var stopCount = 0
  var invalidated = false

  init() {
    let stream = AsyncStream.makeStream(of: HIDHelperConnectionEvent.self)
    events = stream.stream
    continuation = stream.continuation
  }

  func emit(_ event: HIDHelperConnectionEvent) {
    continuation.yield(event)
  }

  func connect() async throws -> HIDHandshake {
    connectCount += 1
    invalidated = false
    return HIDHandshake(helperBuild: "test")
  }

  func startCapture(_ request: HIDCaptureRequest) async throws {
    requests.append(request)
  }

  func heartbeat() async throws {
    heartbeatCount += 1
  }

  func stopCapture() async throws {
    stopCount += 1
  }

  func invalidate() {
    invalidated = true
  }
}
