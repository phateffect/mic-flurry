import Foundation

public struct HIDDeviceCatalog: Codable, Equatable, Sendable {
  public var schemaVersion: UInt16
  public var profiles: [HIDDeviceProfile]

  public init(schemaVersion: UInt16, profiles: [HIDDeviceProfile]) {
    self.schemaVersion = schemaVersion
    self.profiles = profiles
  }

  public func validatedProfile(id: String) throws -> HIDDeviceProfile {
    try validate()
    guard let profile = profiles.first(where: { $0.id == id }) else {
      throw HIDCatalogError.unknownProfile(id)
    }
    return profile
  }

  public func validate() throws {
    guard schemaVersion == 1 else { throw HIDCatalogError.unsupportedSchema(schemaVersion) }
    guard !profiles.isEmpty, profiles.count <= 32 else { throw HIDCatalogError.invalidProfileCount }
    var identifiers: Set<String> = []
    for profile in profiles {
      guard !profile.id.isEmpty, profile.id.utf8.count <= 128 else {
        throw HIDCatalogError.invalidProfileID
      }
      guard identifiers.insert(profile.id).inserted else {
        throw HIDCatalogError.duplicateProfileID(profile.id)
      }
      guard !profile.manufacturer.isEmpty, profile.manufacturer.utf8.count <= 128 else {
        throw HIDCatalogError.invalidManufacturer
      }
      guard (1...32).contains(profile.maximumInterfaces) else {
        throw HIDCatalogError.invalidMaximumInterfaces(profile.maximumInterfaces)
      }
      guard
        (1...MicFlurryHIDProtocolVersion.maximumReportBytes).contains(
          profile.maximumReportBytes)
      else { throw HIDCatalogError.invalidMaximumReportBytes(profile.maximumReportBytes) }
      guard profile.capturePolicy == .allInterfacesAllInputs else {
        throw HIDCatalogError.unsupportedCapturePolicy
      }
    }
  }
}

public struct HIDDeviceProfile: Codable, Equatable, Sendable {
  public var id: String
  public var manufacturer: String
  public var vendorID: UInt32
  public var productID: UInt32
  public var product: String?
  public var transport: String?
  public var maximumInterfaces: Int
  public var maximumReportBytes: Int
  public var capturePolicy: HIDCapturePolicy

  public init(
    id: String,
    manufacturer: String,
    vendorID: UInt32,
    productID: UInt32,
    product: String? = nil,
    transport: String? = nil,
    maximumInterfaces: Int,
    maximumReportBytes: Int,
    capturePolicy: HIDCapturePolicy
  ) {
    self.id = id
    self.manufacturer = manufacturer
    self.vendorID = vendorID
    self.productID = productID
    self.product = product
    self.transport = transport
    self.maximumInterfaces = maximumInterfaces
    self.maximumReportBytes = maximumReportBytes
    self.capturePolicy = capturePolicy
  }
}

public enum HIDCapturePolicy: String, Codable, Equatable, Sendable {
  case allInterfacesAllInputs = "all_interfaces_all_inputs"
}

public enum HIDCatalogError: Error, Equatable, Sendable {
  case unsupportedSchema(UInt16)
  case invalidProfileCount
  case invalidProfileID
  case duplicateProfileID(String)
  case invalidManufacturer
  case invalidMaximumInterfaces(Int)
  case invalidMaximumReportBytes(Int)
  case unsupportedCapturePolicy
  case unknownProfile(String)
  case missingBundledCatalog
}

public enum TrustedHIDDeviceCatalog {
  public static func bundled() throws -> HIDDeviceCatalog {
    guard let url = Bundle.module.url(forResource: "device-profiles", withExtension: "json") else {
      throw HIDCatalogError.missingBundledCatalog
    }
    let catalog = try JSONDecoder().decode(HIDDeviceCatalog.self, from: Data(contentsOf: url))
    try catalog.validate()
    return catalog
  }
}
