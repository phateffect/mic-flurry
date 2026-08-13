import Foundation

public enum MicFlurryHIDProtocolVersion {
  public static let current: UInt16 = 1
  public static let maximumPayloadBytes = 64 * 1_024
  public static let maximumPhysicalDeviceIDBytes = 256
  public static let maximumReportBytes = 1_024
}

public struct HIDCaptureRequest: Codable, Equatable, Sendable {
  public var protocolVersion: UInt16
  public var profileID: String
  public var physicalDeviceID: String?

  public init(
    protocolVersion: UInt16 = MicFlurryHIDProtocolVersion.current,
    profileID: String,
    physicalDeviceID: String? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.profileID = profileID
    self.physicalDeviceID = physicalDeviceID
  }

  public func validate() throws {
    guard protocolVersion == MicFlurryHIDProtocolVersion.current else {
      throw HIDProtocolError.unsupportedVersion(protocolVersion)
    }
    guard !profileID.isEmpty, profileID.utf8.count <= 128 else {
      throw HIDProtocolError.invalidProfileID
    }
    if let physicalDeviceID,
      physicalDeviceID.isEmpty
        || physicalDeviceID.utf8.count > MicFlurryHIDProtocolVersion.maximumPhysicalDeviceIDBytes
    {
      throw HIDProtocolError.invalidPhysicalDeviceID
    }
  }
}

public struct HIDHandshake: Codable, Equatable, Sendable {
  public var protocolVersion: UInt16
  public var helperBuild: String

  public init(
    protocolVersion: UInt16 = MicFlurryHIDProtocolVersion.current,
    helperBuild: String
  ) {
    self.protocolVersion = protocolVersion
    self.helperBuild = helperBuild
  }
}

public struct HIDLeaseMessage: Codable, Equatable, Sendable {
  public var protocolVersion: UInt16

  public init(protocolVersion: UInt16 = MicFlurryHIDProtocolVersion.current) {
    self.protocolVersion = protocolVersion
  }

  public func validate() throws {
    guard protocolVersion == MicFlurryHIDProtocolVersion.current else {
      throw HIDProtocolError.unsupportedVersion(protocolVersion)
    }
  }
}

public enum HIDEventKind: Codable, Equatable, Sendable {
  case rawReport(reportType: UInt32, reportID: UInt32, bytes: Data)
  case value(usagePage: UInt32, usage: UInt32, value: Int64)
}

public struct HIDCaptureEvent: Codable, Equatable, Sendable {
  public var sequence: UInt64
  public var monotonicNanoseconds: UInt64
  public var physicalDeviceID: String
  public var interfaceIndex: UInt16
  public var kind: HIDEventKind

  public init(
    sequence: UInt64,
    monotonicNanoseconds: UInt64,
    physicalDeviceID: String,
    interfaceIndex: UInt16,
    kind: HIDEventKind
  ) {
    self.sequence = sequence
    self.monotonicNanoseconds = monotonicNanoseconds
    self.physicalDeviceID = physicalDeviceID
    self.interfaceIndex = interfaceIndex
    self.kind = kind
  }

  public func validate(maximumReportBytes: Int = MicFlurryHIDProtocolVersion.maximumReportBytes)
    throws
  {
    guard sequence > 0 else { throw HIDProtocolError.invalidSequence }
    guard !physicalDeviceID.isEmpty,
      physicalDeviceID.utf8.count <= MicFlurryHIDProtocolVersion.maximumPhysicalDeviceIDBytes
    else { throw HIDProtocolError.invalidPhysicalDeviceID }
    if case .rawReport(_, _, let bytes) = kind,
      bytes.isEmpty || bytes.count > maximumReportBytes
    {
      throw HIDProtocolError.invalidReportSize(bytes.count)
    }
  }
}

public enum HIDProtocolCodec {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let data = try JSONEncoder().encode(value)
    guard data.count <= MicFlurryHIDProtocolVersion.maximumPayloadBytes else {
      throw HIDProtocolError.payloadTooLarge(data.count)
    }
    return data
  }

  public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    guard data.count <= MicFlurryHIDProtocolVersion.maximumPayloadBytes else {
      throw HIDProtocolError.payloadTooLarge(data.count)
    }
    return try JSONDecoder().decode(type, from: data)
  }
}

public enum HIDProtocolError: Error, Equatable, Sendable {
  case unsupportedVersion(UInt16)
  case invalidProfileID
  case invalidPhysicalDeviceID
  case invalidSequence
  case invalidReportSize(Int)
  case payloadTooLarge(Int)
}

@objc(MicFlurryHIDHelperXPC)
public protocol MicFlurryHIDHelperXPC {
  func handshake(
    _ request: Data,
    withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
  )
  func startCapture(_ request: Data, withReply reply: @escaping @Sendable (NSError?) -> Void)
  func heartbeat(_ request: Data, withReply reply: @escaping @Sendable (NSError?) -> Void)
  func stopCapture(_ request: Data, withReply reply: @escaping @Sendable (NSError?) -> Void)
}

@objc(MicFlurryHIDEventSinkXPC)
public protocol MicFlurryHIDEventSinkXPC {
  func didReceiveHIDEvent(_ event: Data)
  func captureDidStop(_ reason: String)
}
