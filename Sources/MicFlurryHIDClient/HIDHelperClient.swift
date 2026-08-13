import Foundation
import MicFlurryHIDProtocol

public struct HIDDaemonSecurityPolicy: Equatable, Sendable {
  public let helperCodeSigningRequirement: String

  public init(teamID: String) throws {
    guard teamID.count == 10,
      teamID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) })
    else { throw HIDHelperClientError.invalidTeamID }
    helperCodeSigningRequirement =
      "anchor apple generic and identifier \"io.phateffect.MicFlurry.hid-helper\""
      + " and certificate leaf[subject.OU] = \"\(teamID)\""
  }

  #if DEBUG
    public static var developmentAdHoc: HIDDaemonSecurityPolicy {
      HIDDaemonSecurityPolicy(
        uncheckedRequirement: "identifier \"io.phateffect.MicFlurry.hid-helper\""
      )
    }
  #endif

  #if MICFLURRY_PRIVATE_DISTRIBUTION
    public static func privateAdHoc(helperCDHash: String) throws -> HIDDaemonSecurityPolicy {
      guard Self.validCDHash(helperCDHash) else {
        throw HIDHelperClientError.invalidCDHash
      }
      return HIDDaemonSecurityPolicy(
        uncheckedRequirement:
          "identifier \"io.phateffect.MicFlurry.hid-helper\""
          + " and cdhash H\"\(helperCDHash)\""
      )
    }
  #endif

  private init(uncheckedRequirement: String) {
    helperCodeSigningRequirement = uncheckedRequirement
  }

  private static func validCDHash(_ value: String) -> Bool {
    value.count == 40 && value.allSatisfy { $0.isHexDigit }
  }
}

public enum HIDHelperConnectionEvent: Equatable, Sendable {
  case capture(HIDCaptureEvent)
  case stopped(String)
  case interrupted
  case invalidated
}

@MainActor
public protocol HIDHelperTransport: AnyObject {
  var events: AsyncStream<HIDHelperConnectionEvent> { get }
  func connect() async throws -> HIDHandshake
  func startCapture(_ request: HIDCaptureRequest) async throws
  func heartbeat() async throws
  func stopCapture() async throws
  func invalidate()
}

@MainActor
public final class HIDHelperClient {
  public let events: AsyncStream<HIDHelperConnectionEvent>
  public private(set) var connected = false
  public private(set) var captureActive = false
  public private(set) var lastError: String?

  private let transport: any HIDHelperTransport
  private let heartbeatInterval: Duration
  private let eventContinuation: AsyncStream<HIDHelperConnectionEvent>.Continuation
  private var eventTask: Task<Void, Never>?
  private var heartbeatTask: Task<Void, Never>?

  public init(
    transport: any HIDHelperTransport,
    heartbeatInterval: Duration = .seconds(3)
  ) {
    self.transport = transport
    self.heartbeatInterval = heartbeatInterval
    let stream = AsyncStream.makeStream(
      of: HIDHelperConnectionEvent.self,
      bufferingPolicy: .bufferingNewest(256)
    )
    events = stream.stream
    eventContinuation = stream.continuation
  }

  deinit {
    eventContinuation.finish()
  }

  public func connect() async throws {
    guard !connected else { return }
    let handshake = try await transport.connect()
    guard handshake.protocolVersion == MicFlurryHIDProtocolVersion.current else {
      transport.invalidate()
      throw HIDHelperClientError.unsupportedHelperVersion(handshake.protocolVersion)
    }
    connected = true
    lastError = nil
    startEventLoop()
  }

  public func startCapture(profileID: String, physicalDeviceID: String?) async throws {
    if !connected { try await connect() }
    let request = HIDCaptureRequest(
      profileID: profileID,
      physicalDeviceID: physicalDeviceID
    )
    try request.validate()
    try await transport.startCapture(request)
    captureActive = true
    startHeartbeat()
  }

  public func stopCapture() async throws {
    heartbeatTask?.cancel()
    heartbeatTask = nil
    guard captureActive else { return }
    defer { captureActive = false }
    try await transport.stopCapture()
  }

  public func shutdown() async {
    try? await stopCapture()
    eventTask?.cancel()
    eventTask = nil
    connected = false
    transport.invalidate()
    eventContinuation.finish()
  }

  private func startEventLoop() {
    guard eventTask == nil else { return }
    let incoming = transport.events
    eventTask = Task { [weak self] in
      var eventsSinceYield = 0
      for await event in incoming {
        guard let self else { return }
        receive(event)
        eventsSinceYield += 1
        if eventsSinceYield == 16 {
          eventsSinceYield = 0
          await Task.yield()
        }
      }
    }
  }

  private func startHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        do {
          try await Task.sleep(for: heartbeatInterval)
          if Task.isCancelled { return }
          try await transport.heartbeat()
        } catch is CancellationError {
          return
        } catch {
          fail(error)
          return
        }
      }
    }
  }

  private func receive(_ event: HIDHelperConnectionEvent) {
    switch event {
    case .capture:
      break
    case .stopped(let reason):
      captureActive = false
      heartbeatTask?.cancel()
      heartbeatTask = nil
      lastError = reason
    case .interrupted, .invalidated:
      connected = false
      captureActive = false
      heartbeatTask?.cancel()
      heartbeatTask = nil
    }
    eventContinuation.yield(event)
  }

  private func fail(_ error: any Error) {
    lastError = String(describing: error)
    connected = false
    captureActive = false
    heartbeatTask?.cancel()
    heartbeatTask = nil
    transport.invalidate()
    eventContinuation.yield(.invalidated)
  }
}

public enum HIDHelperClientError: Error, Equatable, Sendable {
  case invalidTeamID
  case invalidCDHash
  case unsupportedHelperVersion(UInt16)
  case unavailable
  case malformedEvent
}
