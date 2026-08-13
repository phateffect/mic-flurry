import Foundation
import IOKit.hid

public struct HIDIdentity: Equatable, Sendable {
  public var manufacturer: String?
  public var product: String?
  public var vendorID: UInt32?
  public var productID: UInt32?
  public var transport: String?
  public var serialNumber: String?
  public var versionNumber: UInt32?
  public var physicalDeviceID: String?

  public init() {}
}

public enum HIDIdentityProvider {
  public static func identities() -> [UUID: HIDIdentity] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, nil)
    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [:] }

    var result: [UUID: HIDIdentity] = [:]
    for device in devices {
      guard let physicalDeviceID = stringProperty(device, key: "PhysicalDeviceUniqueID"),
        let identifier = UUID(uuidString: physicalDeviceID)
      else { continue }
      var identity = result[identifier] ?? HIDIdentity()
      identity.manufacturer = identity.manufacturer ?? stringProperty(device, key: "Manufacturer")
      identity.product = identity.product ?? stringProperty(device, key: "Product")
      identity.vendorID = identity.vendorID ?? numberProperty(device, key: "VendorID")
      identity.productID = identity.productID ?? numberProperty(device, key: "ProductID")
      identity.transport = identity.transport ?? stringProperty(device, key: "Transport")
      identity.serialNumber = identity.serialNumber ?? stringProperty(device, key: "SerialNumber")
      identity.versionNumber =
        identity.versionNumber ?? numberProperty(device, key: "VersionNumber")
      identity.physicalDeviceID = physicalDeviceID
      result[identifier] = identity
    }
    return result
  }

  public static func isSupportedRC003(_ identity: HIDIdentity?) -> Bool {
    identity?.manufacturer == "MIOM"
      && identity?.vendorID == 0x2717
      && identity?.productID == 0x32b8
  }

  private static func stringProperty(_ device: IOHIDDevice, key: String) -> String? {
    IOHIDDeviceGetProperty(device, key as CFString) as? String
  }

  private static func numberProperty(_ device: IOHIDDevice, key: String) -> UInt32? {
    (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.uint32Value
  }
}
