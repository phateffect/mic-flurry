@preconcurrency import Foundation
import MicFlurryHIDProtocol

@MainActor
public final class HIDHelperXPCTransport: HIDHelperTransport {
  public let events: AsyncStream<HIDHelperConnectionEvent>

  private let securityPolicy: HIDDaemonSecurityPolicy
  private let eventContinuation: AsyncStream<HIDHelperConnectionEvent>.Continuation
  private let eventSink: HIDHelperEventSink
  private var connection: NSXPCConnection?

  public init(securityPolicy: HIDDaemonSecurityPolicy) {
    self.securityPolicy = securityPolicy
    let stream = AsyncStream.makeStream(
      of: HIDHelperConnectionEvent.self,
      bufferingPolicy: .bufferingNewest(256)
    )
    events = stream.stream
    eventContinuation = stream.continuation
    eventSink = HIDHelperEventSink(continuation: stream.continuation)
  }

  deinit {
    eventContinuation.finish()
  }

  public func connect() async throws -> HIDHandshake {
    if connection == nil { configureConnection() }
    let message = try HIDProtocolCodec.encode(HIDLeaseMessage())
    let data = try await call { proxy, reply in
      proxy.handshake(message, withReply: reply)
    }
    guard let data else { throw HIDHelperClientError.unavailable }
    return try HIDProtocolCodec.decode(HIDHandshake.self, from: data)
  }

  public func startCapture(_ request: HIDCaptureRequest) async throws {
    let data = try HIDProtocolCodec.encode(request)
    try await callVoid { proxy, reply in
      proxy.startCapture(data, withReply: reply)
    }
  }

  public func heartbeat() async throws {
    let data = try HIDProtocolCodec.encode(HIDLeaseMessage())
    try await callVoid { proxy, reply in
      proxy.heartbeat(data, withReply: reply)
    }
  }

  public func stopCapture() async throws {
    let data = try HIDProtocolCodec.encode(HIDLeaseMessage())
    try await callVoid { proxy, reply in
      proxy.stopCapture(data, withReply: reply)
    }
  }

  public func invalidate() {
    let connection = self.connection
    self.connection = nil
    connection?.invalidationHandler = nil
    connection?.interruptionHandler = nil
    connection?.invalidate()
  }

  private func configureConnection() {
    let connection = NSXPCConnection(
      machServiceName: "io.phateffect.MicFlurry.hid-helper",
      options: .privileged
    )
    connection.setCodeSigningRequirement(securityPolicy.helperCodeSigningRequirement)
    connection.remoteObjectInterface = NSXPCInterface(with: MicFlurryHIDHelperXPC.self)
    connection.exportedInterface = NSXPCInterface(with: MicFlurryHIDEventSinkXPC.self)
    connection.exportedObject = eventSink
    connection.interruptionHandler = { [weak self] in
      Task { @MainActor in self?.eventContinuation.yield(.interrupted) }
    }
    connection.invalidationHandler = { [weak self, weak connection] in
      Task { @MainActor in
        guard let self else { return }
        if self.connection === connection { self.connection = nil }
        self.eventContinuation.yield(.invalidated)
      }
    }
    self.connection = connection
    connection.activate()
  }

  private func call(
    _ body: (any MicFlurryHIDHelperXPC, @escaping @Sendable (Data?, NSError?) -> Void) -> Void
  ) async throws -> Data? {
    return try await withCheckedThrowingContinuation { continuation in
      let replyGate = XPCReplyGate(continuation)
      guard
        let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
          replyGate.resume(throwing: error)
        }) as? any MicFlurryHIDHelperXPC
      else {
        replyGate.resume(throwing: HIDHelperClientError.unavailable)
        return
      }
      body(proxy) { data, error in
        if let error {
          replyGate.resume(throwing: error)
        } else {
          replyGate.resume(returning: data)
        }
      }
    }
  }

  private func callVoid(
    _ body: (any MicFlurryHIDHelperXPC, @escaping @Sendable (NSError?) -> Void) -> Void
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      let replyGate = XPCReplyGate(continuation)
      guard
        let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
          replyGate.resume(throwing: error)
        }) as? any MicFlurryHIDHelperXPC
      else {
        replyGate.resume(throwing: HIDHelperClientError.unavailable)
        return
      }
      body(proxy) { error in
        if let error {
          replyGate.resume(throwing: error)
        } else {
          replyGate.resume(returning: ())
        }
      }
    }
  }
}

private final class XPCReplyGate<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, any Error>?

  init(_ continuation: CheckedContinuation<Value, any Error>) {
    self.continuation = continuation
  }

  func resume(returning value: Value) {
    takeContinuation()?.resume(returning: value)
  }

  func resume(throwing error: any Error) {
    takeContinuation()?.resume(throwing: error)
  }

  private func takeContinuation() -> CheckedContinuation<Value, any Error>? {
    lock.lock()
    defer { lock.unlock() }
    let continuation = self.continuation
    self.continuation = nil
    return continuation
  }
}

private final class HIDHelperEventSink: NSObject, MicFlurryHIDEventSinkXPC {
  private let continuation: AsyncStream<HIDHelperConnectionEvent>.Continuation

  init(continuation: AsyncStream<HIDHelperConnectionEvent>.Continuation) {
    self.continuation = continuation
  }

  func didReceiveHIDEvent(_ event: Data) {
    guard let event = try? HIDProtocolCodec.decode(HIDCaptureEvent.self, from: event),
      (try? event.validate()) != nil
    else {
      continuation.yield(.invalidated)
      return
    }
    continuation.yield(.capture(event))
  }

  func captureDidStop(_ reason: String) {
    continuation.yield(.stopped(reason))
  }
}
