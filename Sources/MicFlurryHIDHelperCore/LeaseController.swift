import Foundation
import MicFlurryHIDProtocol

public struct HIDLeaseOwner: Hashable, Sendable {
  fileprivate let token: UUID

  public init() {
    token = UUID()
  }
}

@MainActor
public protocol HIDCaptureBackend: AnyObject {
  func start(profile: HIDDeviceProfile, physicalDeviceID: String?) throws
  func stop()
}

@MainActor
public final class HIDLeaseController {
  public static let defaultHeartbeatTimeoutNanoseconds: UInt64 = 10_000_000_000

  private let catalog: HIDDeviceCatalog
  private let backend: any HIDCaptureBackend
  private let heartbeatTimeoutNanoseconds: UInt64
  private let now: @MainActor () -> UInt64
  private var lease: Lease?

  public init(
    catalog: HIDDeviceCatalog,
    backend: any HIDCaptureBackend,
    heartbeatTimeoutNanoseconds: UInt64 = defaultHeartbeatTimeoutNanoseconds,
    now: @escaping @MainActor () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
  ) throws {
    try catalog.validate()
    guard heartbeatTimeoutNanoseconds > 0 else {
      throw HIDLeaseError.invalidHeartbeatTimeout
    }
    self.catalog = catalog
    self.backend = backend
    self.heartbeatTimeoutNanoseconds = heartbeatTimeoutNanoseconds
    self.now = now
  }

  public var active: Bool { lease != nil }

  public func start(
    owner: HIDLeaseOwner,
    request: HIDCaptureRequest,
    isOwnerValid: @MainActor () -> Bool = { true }
  ) throws {
    try request.validate()
    guard lease == nil else { throw HIDCaptureError.captureOwnedByAnotherClient }
    guard isOwnerValid() else { throw HIDLeaseError.ownerInvalidatedDuringStart }
    let profile = try catalog.validatedProfile(id: request.profileID)
    try backend.start(profile: profile, physicalDeviceID: request.physicalDeviceID)
    guard isOwnerValid() else {
      backend.stop()
      throw HIDLeaseError.ownerInvalidatedDuringStart
    }
    lease = Lease(
      owner: owner,
      deadlineNanoseconds: now().addingClamped(heartbeatTimeoutNanoseconds)
    )
  }

  public func heartbeat(owner: HIDLeaseOwner) throws {
    guard let lease else { throw HIDCaptureError.noActiveLease }
    guard lease.owner == owner else { throw HIDCaptureError.wrongLeaseOwner }
    self.lease?.deadlineNanoseconds = now().addingClamped(heartbeatTimeoutNanoseconds)
  }

  public func stop(owner: HIDLeaseOwner) throws {
    guard let lease else { return }
    guard lease.owner == owner else { throw HIDCaptureError.wrongLeaseOwner }
    release()
  }

  public func connectionInvalidated(owner: HIDLeaseOwner) {
    guard lease?.owner == owner else { return }
    release()
  }

  @discardableResult
  public func backendStoppedUnexpectedly() -> Bool {
    guard lease != nil else { return false }
    lease = nil
    return true
  }

  @discardableResult
  public func expireIfNeeded() -> Bool {
    guard let lease, now() >= lease.deadlineNanoseconds else { return false }
    release()
    return true
  }

  private func release() {
    guard lease != nil else { return }
    lease = nil
    backend.stop()
  }
}

private struct Lease {
  var owner: HIDLeaseOwner
  var deadlineNanoseconds: UInt64
}

public enum HIDLeaseError: Error, Equatable, Sendable {
  case invalidHeartbeatTimeout
  case ownerInvalidatedDuringStart
}

extension UInt64 {
  fileprivate func addingClamped(_ value: UInt64) -> UInt64 {
    let (result, overflow) = addingReportingOverflow(value)
    return overflow ? .max : result
  }
}
