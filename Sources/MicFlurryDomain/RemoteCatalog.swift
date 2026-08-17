public struct RemoteHIDFingerprint: Equatable, Sendable {
  public var manufacturer: String
  public var vendorID: UInt32
  public var productID: UInt32

  public init(manufacturer: String, vendorID: UInt32, productID: UInt32) {
    self.manufacturer = manufacturer
    self.vendorID = vendorID
    self.productID = productID
  }
}

public struct RemoteDISFingerprint: Equatable, Sendable {
  public var manufacturer: String
  public var modelNumber: String
  public var hardwareRevision: String

  public init(manufacturer: String, modelNumber: String, hardwareRevision: String) {
    self.manufacturer = manufacturer
    self.modelNumber = modelNumber
    self.hardwareRevision = hardwareRevision
  }
}

public struct RemoteProfile: Equatable, Sendable {
  public var model: String
  public var hidProfileID: String
  public var hid: RemoteHIDFingerprint
  public var dis: RemoteDISFingerprint

  public init(
    model: String,
    hidProfileID: String,
    hid: RemoteHIDFingerprint,
    dis: RemoteDISFingerprint
  ) {
    self.model = model
    self.hidProfileID = hidProfileID
    self.hid = hid
    self.dis = dis
  }
}

public enum RemoteCatalog {
  private static let xiaomiRemoteActions: [KeyboardAction] = [
    .power, .microphone,
    .up, .down, .left, .right, .select,
    .back, .home, .menu,
    .volumeDown, .volumeUp, .tv,
  ]

  private static let xiaomiHID = RemoteHIDFingerprint(
    manufacturer: "MIOM",
    vendorID: 0x2717,
    productID: 0x32b8
  )

  public static let profiles = [
    RemoteProfile(
      model: "mi-rc001",
      hidProfileID: "rc001-v1",
      hid: xiaomiHID,
      dis: RemoteDISFingerprint(
        manufacturer: "MIOM",
        modelNumber: "RC001",
        hardwareRevision: "V2.0"
      )
    ),
    RemoteProfile(
      model: "mi-rc003",
      hidProfileID: "rc003-v1",
      hid: xiaomiHID,
      dis: RemoteDISFingerprint(
        manufacturer: "MIOM",
        modelNumber: "RC003",
        hardwareRevision: "V2.0"
      )
    ),
  ]

  public static func contains(hid fingerprint: RemoteHIDFingerprint) -> Bool {
    profiles.contains { $0.hid == fingerprint }
  }

  public static func profile(model: String) -> RemoteProfile? {
    profiles.first { $0.model == model }
  }

  public static func keymapActions(model: String) -> [KeyboardAction]? {
    guard profile(model: model) != nil else { return nil }
    return xiaomiRemoteActions
  }

  public static func profile(hid: RemoteHIDFingerprint, dis: RemoteDISFingerprint) -> RemoteProfile?
  {
    profiles.first { $0.hid == hid && $0.dis == dis }
  }

  public static func profile(deviceInfo: DeviceInfo) -> RemoteProfile? {
    guard
      let hidManufacturer = deviceInfo.hidManufacturer,
      let hidVendorID = deviceInfo.hidVendorID,
      let hidProductID = deviceInfo.hidProductID,
      let manufacturer = deviceInfo.manufacturerName,
      let modelNumber = deviceInfo.modelNumber,
      let hardwareRevision = deviceInfo.hardwareRevision
    else { return nil }
    return profile(
      hid: RemoteHIDFingerprint(
        manufacturer: hidManufacturer,
        vendorID: hidVendorID,
        productID: hidProductID
      ),
      dis: RemoteDISFingerprint(
        manufacturer: manufacturer,
        modelNumber: modelNumber,
        hardwareRevision: hardwareRevision
      )
    )
  }
}
