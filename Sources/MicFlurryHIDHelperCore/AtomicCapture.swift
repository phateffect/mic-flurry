import Foundation
import MicFlurryHIDProtocol

public struct HIDInterfaceDescriptor: Equatable, Sendable {
  public var identifier: String
  public var physicalDeviceID: String
  public var manufacturer: String?
  public var vendorID: UInt32?
  public var productID: UInt32?
  public var product: String?
  public var transport: String?
  public var maximumInputReportBytes: Int

  public init(
    identifier: String,
    physicalDeviceID: String,
    manufacturer: String?,
    vendorID: UInt32?,
    productID: UInt32?,
    product: String?,
    transport: String?,
    maximumInputReportBytes: Int
  ) {
    self.identifier = identifier
    self.physicalDeviceID = physicalDeviceID
    self.manufacturer = manufacturer
    self.vendorID = vendorID
    self.productID = productID
    self.product = product
    self.transport = transport
    self.maximumInputReportBytes = maximumInputReportBytes
  }
}

public enum HIDInterfaceSelection {
  public static func select(
    _ interfaces: [HIDInterfaceDescriptor],
    profile: HIDDeviceProfile,
    physicalDeviceID: String?
  ) throws -> [HIDInterfaceDescriptor] {
    let matching = interfaces.filter { descriptor in
      descriptor.manufacturer == profile.manufacturer
        && descriptor.vendorID == profile.vendorID
        && descriptor.productID == profile.productID
        && profile.product.map { $0 == descriptor.product } ?? true
        && profile.transport.map { $0 == descriptor.transport } ?? true
    }
    let groups = Dictionary(grouping: matching, by: \HIDInterfaceDescriptor.physicalDeviceID)
    let selectedID: String
    if let physicalDeviceID {
      guard groups[physicalDeviceID] != nil else {
        throw HIDCaptureError.physicalDeviceNotFound(physicalDeviceID)
      }
      selectedID = physicalDeviceID
    } else {
      guard groups.count == 1, let identifier = groups.keys.first else {
        if groups.isEmpty { throw HIDCaptureError.noMatchingDevice }
        throw HIDCaptureError.physicalDeviceIDRequired
      }
      selectedID = identifier
    }
    let selected = (groups[selectedID] ?? []).sorted { $0.identifier < $1.identifier }
    guard selected.count <= profile.maximumInterfaces else {
      throw HIDCaptureError.tooManyInterfaces(selected.count)
    }
    guard
      selected.allSatisfy({
        $0.maximumInputReportBytes > 0
          && $0.maximumInputReportBytes <= profile.maximumReportBytes
      })
    else { throw HIDCaptureError.invalidReportSize }
    return selected
  }
}

@MainActor
public protocol HIDCaptureInterface: AnyObject {
  var descriptor: HIDInterfaceDescriptor { get }
  func openSeized() throws
  func installCallbacks(interfaceIndex: UInt16) throws
  func uninstallCallbacks()
  func close()
}

@MainActor
public final class AtomicHIDCapture {
  private var active: [any HIDCaptureInterface] = []

  public init() {}

  public var activeInterfaceCount: Int { active.count }

  public func start(interfaces: [any HIDCaptureInterface]) throws {
    guard active.isEmpty else { throw HIDCaptureError.captureAlreadyActive }
    var opened: [any HIDCaptureInterface] = []
    do {
      for interface in interfaces {
        try interface.openSeized()
        opened.append(interface)
      }
      for (index, interface) in opened.enumerated() {
        try interface.installCallbacks(interfaceIndex: UInt16(index))
      }
      active = opened
    } catch {
      for interface in opened.reversed() {
        interface.uninstallCallbacks()
        interface.close()
      }
      throw error
    }
  }

  public func stop() {
    let interfaces = active
    active.removeAll()
    for interface in interfaces.reversed() {
      interface.uninstallCallbacks()
    }
    for interface in interfaces.reversed() {
      interface.close()
    }
  }
}

public enum HIDCaptureError: Error, Equatable, Sendable {
  case noMatchingDevice
  case physicalDeviceIDRequired
  case physicalDeviceNotFound(String)
  case tooManyInterfaces(Int)
  case invalidReportSize
  case captureAlreadyActive
  case captureOwnedByAnotherClient
  case noActiveLease
  case wrongLeaseOwner
}
