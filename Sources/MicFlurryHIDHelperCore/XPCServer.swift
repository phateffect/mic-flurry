import Darwin
import Foundation
import MicFlurryHIDProtocol
import SystemConfiguration

@MainActor
public final class HIDHelperXPCServer: NSObject, NSXPCListenerDelegate {
  public static let machServiceName = "io.phateffect.MicFlurry.hid-helper"

  private let listener: NSXPCListener
  private let securityPolicy: HIDHelperSecurityPolicy
  private let eventForwarder = HIDEventForwarder()
  private let leaseController: HIDLeaseController
  private var services: [ObjectIdentifier: HIDHelperXPCService] = [:]
  private var expiryTimer: Timer?

  public init(securityPolicy: HIDHelperSecurityPolicy) throws {
    let catalog = try TrustedHIDDeviceCatalog.bundled()
    let forwarder = eventForwarder
    let backend = IOHIDCaptureBackend { event in
      forwarder.send(event)
    }
    leaseController = try HIDLeaseController(catalog: catalog, backend: backend)
    self.securityPolicy = securityPolicy
    listener = NSXPCListener(machServiceName: Self.machServiceName)
    super.init()
    backend.unexpectedStopSink = { [weak self] reason in
      self?.captureBackendStopped(reason: reason)
    }
    listener.delegate = self
  }

  public func run() throws -> Never {
    guard geteuid() == 0 else { throw HIDHelperSecurityError.notRoot }
    expiryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        if let owner = self.eventForwarder.owner,
          self.eventForwarder.ownerUID != Self.consoleUserID()
        {
          self.leaseController.connectionInvalidated(owner: owner)
          self.eventForwarder.stop(reason: "console_user_changed")
        } else if self.leaseController.expireIfNeeded() {
          self.eventForwarder.stop(reason: "heartbeat_timeout")
        }
      }
    }
    listener.resume()
    RunLoop.main.run()
    fatalError("XPC listener run loop exited")
  }

  public nonisolated func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    let transferred = UncheckedTransfer(connection)
    if Thread.isMainThread {
      return MainActor.assumeIsolated { accept(transferred.value) }
    }
    return DispatchQueue.main.sync {
      MainActor.assumeIsolated { accept(transferred.value) }
    }
  }

  private func accept(_ connection: NSXPCConnection) -> Bool {
    guard
      securityPolicy.accepts(
        effectiveUID: connection.effectiveUserIdentifier,
        consoleUID: Self.consoleUserID()
      )
    else { return false }

    connection.setCodeSigningRequirement(securityPolicy.daemonCodeSigningRequirement)
    let owner = HIDLeaseOwner()
    let validity = HIDConnectionValidity()
    let service = HIDHelperXPCService(
      owner: owner,
      validity: validity,
      connection: connection,
      leaseController: leaseController,
      eventForwarder: eventForwarder
    )
    let identifier = ObjectIdentifier(connection)
    connection.exportedInterface = NSXPCInterface(with: MicFlurryHIDHelperXPC.self)
    connection.exportedObject = service
    connection.remoteObjectInterface = NSXPCInterface(with: MicFlurryHIDEventSinkXPC.self)
    connection.interruptionHandler = { [weak self] in
      validity.invalidate()
      Task { @MainActor in self?.connectionEnded(identifier, owner: owner) }
    }
    connection.invalidationHandler = { [weak self] in
      validity.invalidate()
      Task { @MainActor in self?.connectionEnded(identifier, owner: owner) }
    }
    services[identifier] = service
    connection.activate()
    return true
  }

  private func connectionEnded(_ identifier: ObjectIdentifier, owner: HIDLeaseOwner) {
    leaseController.connectionInvalidated(owner: owner)
    eventForwarder.clear(owner: owner)
    services.removeValue(forKey: identifier)
  }

  private func captureBackendStopped(reason: String) {
    guard leaseController.backendStoppedUnexpectedly() else { return }
    eventForwarder.stop(reason: reason)
  }

  fileprivate static func consoleUserID() -> uid_t? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard let user = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
      user != "loginwindow",
      uid != 0
    else { return nil }
    return uid
  }
}

@MainActor
private final class HIDEventForwarder {
  private(set) var owner: HIDLeaseOwner?
  private(set) var ownerUID: uid_t?
  private var sink: (any MicFlurryHIDEventSinkXPC)?

  func bind(owner: HIDLeaseOwner, ownerUID: uid_t, sink: any MicFlurryHIDEventSinkXPC) {
    self.owner = owner
    self.ownerUID = ownerUID
    self.sink = sink
  }

  func send(_ event: HIDCaptureEvent) {
    guard let sink, let data = try? HIDProtocolCodec.encode(event) else { return }
    sink.didReceiveHIDEvent(data)
  }

  func stop(reason: String) {
    sink?.captureDidStop(reason)
    owner = nil
    ownerUID = nil
    sink = nil
  }

  func clear(owner: HIDLeaseOwner) {
    guard self.owner == owner else { return }
    self.owner = nil
    ownerUID = nil
    sink = nil
  }
}

@MainActor
private final class HIDHelperXPCService: NSObject, MicFlurryHIDHelperXPC {
  private let owner: HIDLeaseOwner
  private let validity: HIDConnectionValidity
  private weak var connection: NSXPCConnection?
  private let leaseController: HIDLeaseController
  private let eventForwarder: HIDEventForwarder

  init(
    owner: HIDLeaseOwner,
    validity: HIDConnectionValidity,
    connection: NSXPCConnection,
    leaseController: HIDLeaseController,
    eventForwarder: HIDEventForwarder
  ) {
    self.owner = owner
    self.validity = validity
    self.connection = connection
    self.leaseController = leaseController
    self.eventForwarder = eventForwarder
  }

  nonisolated func handshake(
    _ request: Data,
    withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
  ) {
    Task { @MainActor [weak self] in self?.handleHandshake(request, reply: reply) }
  }

  nonisolated func startCapture(
    _ request: Data,
    withReply reply: @escaping @Sendable (NSError?) -> Void
  ) {
    Task { @MainActor [weak self] in self?.handleStartCapture(request, reply: reply) }
  }

  nonisolated func heartbeat(
    _ request: Data,
    withReply reply: @escaping @Sendable (NSError?) -> Void
  ) {
    Task { @MainActor [weak self] in self?.handleHeartbeat(request, reply: reply) }
  }

  nonisolated func stopCapture(
    _ request: Data,
    withReply reply: @escaping @Sendable (NSError?) -> Void
  ) {
    Task { @MainActor [weak self] in self?.handleStopCapture(request, reply: reply) }
  }

  private func handleHandshake(_ request: Data, reply: @escaping (Data?, NSError?) -> Void) {
    do {
      let message = try HIDProtocolCodec.decode(HIDLeaseMessage.self, from: request)
      try message.validate()
      let response = HIDHandshake(helperBuild: Self.helperBuild)
      reply(try HIDProtocolCodec.encode(response), nil)
    } catch {
      reply(nil, Self.sanitizedError(error))
    }
  }

  private func handleStartCapture(_ request: Data, reply: @escaping (NSError?) -> Void) {
    do {
      let message = try HIDProtocolCodec.decode(HIDCaptureRequest.self, from: request)
      guard
        let sink = connection?.remoteObjectProxyWithErrorHandler({ _ in })
          as? any MicFlurryHIDEventSinkXPC
      else { throw HIDHelperXPCError.missingEventSink }
      guard let connection,
        connection.effectiveUserIdentifier == HIDHelperXPCServer.consoleUserID()
      else { throw HIDHelperXPCError.staleConsoleSession }
      try leaseController.start(
        owner: owner,
        request: message,
        isOwnerValid: { self.validity.isValid }
      )
      eventForwarder.bind(
        owner: owner,
        ownerUID: connection.effectiveUserIdentifier,
        sink: sink
      )
      reply(nil)
    } catch {
      reply(Self.sanitizedError(error))
    }
  }

  private func handleHeartbeat(_ request: Data, reply: @escaping (NSError?) -> Void) {
    do {
      let message = try HIDProtocolCodec.decode(HIDLeaseMessage.self, from: request)
      try message.validate()
      guard let connection,
        connection.effectiveUserIdentifier == HIDHelperXPCServer.consoleUserID()
      else {
        leaseController.connectionInvalidated(owner: owner)
        eventForwarder.clear(owner: owner)
        throw HIDHelperXPCError.staleConsoleSession
      }
      try leaseController.heartbeat(owner: owner)
      reply(nil)
    } catch {
      reply(Self.sanitizedError(error))
    }
  }

  private func handleStopCapture(_ request: Data, reply: @escaping (NSError?) -> Void) {
    do {
      let message = try HIDProtocolCodec.decode(HIDLeaseMessage.self, from: request)
      try message.validate()
      try leaseController.stop(owner: owner)
      eventForwarder.stop(reason: "explicit_stop")
      reply(nil)
    } catch {
      reply(Self.sanitizedError(error))
    }
  }

  private static let helperBuild =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"

  private static func sanitizedError(_ error: any Error) -> NSError {
    NSError(
      domain: "io.phateffect.MicFlurry.hid-helper",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: String(describing: error)]
    )
  }
}

private enum HIDHelperXPCError: Error {
  case missingEventSink
  case staleConsoleSession
}

final class HIDConnectionValidity: @unchecked Sendable {
  private let lock = NSLock()
  private var valid = true

  var isValid: Bool {
    lock.lock()
    defer { lock.unlock() }
    return valid
  }

  func invalidate() {
    lock.lock()
    valid = false
    lock.unlock()
  }
}

private struct UncheckedTransfer<Value>: @unchecked Sendable {
  let value: Value

  init(_ value: Value) {
    self.value = value
  }
}
