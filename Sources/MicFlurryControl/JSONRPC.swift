import Foundation
import MicFlurryDomain

public indirect enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

public enum JSONRPCID: Codable, Equatable, Sendable {
  case integer(Int64)
  case string(String)
  case null

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else {
      self = .string(try container.decode(String.self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .integer(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

public struct JSONRPCRequest: Codable, Equatable, Sendable {
  public var jsonrpc: String
  public var id: JSONRPCID?
  public var method: String
  public var params: JSONValue?

  public init(
    jsonrpc: String = "2.0",
    id: JSONRPCID?,
    method: String,
    params: JSONValue? = nil
  ) {
    self.jsonrpc = jsonrpc
    self.id = id
    self.method = method
    self.params = params
  }
}

public struct JSONRPCError: Codable, Equatable, Sendable {
  public var code: Int
  public var message: String

  public init(code: Int, message: String) {
    self.code = code
    self.message = message
  }
}

public struct JSONRPCResponse: Codable, Equatable, Sendable {
  public var jsonrpc = "2.0"
  public var id: JSONRPCID
  public var result: JSONValue?
  public var error: JSONRPCError?

  public init(id: JSONRPCID, result: JSONValue) {
    self.id = id
    self.result = result
  }

  public init(id: JSONRPCID, error: JSONRPCError) {
    self.id = id
    self.error = error
  }
}

public struct JSONRPCNotification: Codable, Equatable, Sendable {
  public var jsonrpc = "2.0"
  public var method: String
  public var params: JSONValue

  public init(method: String, params: JSONValue) {
    self.method = method
    self.params = params
  }
}

public enum JSONRPCCodec {
  public static let maximumFrameBytes = 64 * 1_024

  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .custom { path in
      let key = path.last?.stringValue ?? ""
      let parts = key.split(separator: "_", omittingEmptySubsequences: false)
      guard parts.count > 1 else { return AnyCodingKey(key) }
      let converted = parts.dropFirst().reduce(String(parts[0])) { result, part in
        let word = String(part)
        let abbreviation = [
          "atvv": "ATVV",
          "db": "DB",
          "dbfs": "DBFS",
          "id": "ID",
          "uid": "UID",
        ][word]
        return result + (abbreviation ?? word.prefix(1).uppercased() + word.dropFirst())
      }
      return AnyCodingKey(converted)
    }
    return decoder
  }

  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  public static func value<T: Encodable>(_ value: T) throws -> JSONValue {
    try decoder().decode(JSONValue.self, from: encoder().encode(value))
  }

  public static func eventValue(_ event: Event) throws -> JSONValue {
    var fields: [String: JSONValue]
    switch event {
    case .status(let status):
      fields = ["type": .string("status"), "status": try value(status)]
    case .deviceDiscovered(let device):
      fields = ["type": .string("device_discovered"), "device": try value(device)]
    case .attaching(let device, let active):
      fields = [
        "type": .string("attaching"),
        "device": try value(device),
        "active": .bool(active),
      ]
    case .connected(let device):
      fields = ["type": .string("connected"), "device": try value(device)]
    case .disconnected(let device):
      fields = ["type": .string("disconnected"), "device": try value(device)]
    case .audioStarted(let rateHz):
      fields = ["type": .string("audio_started"), "rate_hz": .integer(Int64(rateHz))]
    case .audioLevel(let dbfs):
      fields = ["type": .string("audio_level"), "dbfs": .number(Double(dbfs))]
    case .audioStopped:
      fields = ["type": .string("audio_stopped")]
    case .recordingStarted(let path):
      fields = ["type": .string("recording_started"), "path": .string(path)]
    case .recordingStopped(let path, let sampleCount):
      fields = [
        "type": .string("recording_stopped"),
        "path": .string(path),
        "sample_count": .integer(Int64(clamping: sampleCount)),
      ]
    case .hidInput(let input):
      fields = ["type": .string("hid_input"), "input": try value(input)]
    case .keyboardOutput(let output):
      fields = ["type": .string("keyboard_output"), "output": try value(output)]
    case .error(let message):
      fields = ["type": .string("error"), "message": .string(message)]
    }
    return .object(fields)
  }

  public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue?) throws -> T {
    guard let value else { throw ControlProtocolError.invalidParams("params are required") }
    return try decoder().decode(type, from: encoder().encode(value))
  }

  public static func line<T: Encodable>(_ value: T) throws -> Data {
    var data = try encoder().encode(value)
    guard data.count < maximumFrameBytes else { throw ControlProtocolError.frameTooLarge }
    data.append(0x0a)
    return data
  }
}

private struct AnyCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init(_ stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(stringValue: String) {
    self.init(stringValue)
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}

public enum ControlProtocolError: Error, Equatable, Sendable {
  case invalidRequest(String)
  case invalidParams(String)
  case frameTooLarge
  case socket(String)
}

@MainActor
public protocol ControlService: AnyObject {
  var events: AsyncStream<Event> { get }
  func controlStatus() -> Status
  func controlSettings() -> Settings
  func controlSetSettings(_ change: SettingsChange) throws -> Settings
  func controlRefreshDevices() async throws
  func controlConnect(to deviceID: DeviceID) async throws
  func controlRelease() async throws
  func controlStartRecording() throws
  func controlStopRecording() throws
  func controlStartHIDCapture() async throws
  func controlStopHIDCapture() async throws
}

public enum ControlMethods {
  public static let status = "v1.status"
  public static let settings = "v1.settings"
  public static let setSettings = "v1.set_settings"
  public static let refreshDevices = "v1.refresh_devices"
  public static let connect = "v1.connect"
  public static let release = "v1.release"
  public static let startRecording = "v1.start_recording"
  public static let stopRecording = "v1.stop_recording"
  public static let startHIDCapture = "v1.start_hid_capture"
  public static let stopHIDCapture = "v1.stop_hid_capture"
  public static let event = "v1.event"
}

private struct ConnectParameters: Codable {
  let device: DeviceID
}

@MainActor
public enum ControlRouter {
  public static func route(
    _ request: JSONRPCRequest,
    to service: any ControlService
  ) async -> JSONRPCResponse? {
    guard let id = request.id else { return nil }
    guard request.jsonrpc == "2.0" else {
      return JSONRPCResponse(
        id: id,
        error: JSONRPCError(code: -32_600, message: "invalid JSON-RPC version")
      )
    }
    do {
      let result: JSONValue
      switch request.method {
      case ControlMethods.status:
        result = try JSONRPCCodec.value(service.controlStatus())
      case ControlMethods.settings:
        result = try JSONRPCCodec.value(service.controlSettings())
      case ControlMethods.setSettings:
        let change = try JSONRPCCodec.decode(SettingsChange.self, from: request.params)
        result = try JSONRPCCodec.value(service.controlSetSettings(change))
      case ControlMethods.refreshDevices:
        try await service.controlRefreshDevices()
        result = .null
      case ControlMethods.connect:
        let parameters = try JSONRPCCodec.decode(ConnectParameters.self, from: request.params)
        try await service.controlConnect(to: parameters.device)
        result = .null
      case ControlMethods.release:
        try await service.controlRelease()
        result = .null
      case ControlMethods.startRecording:
        try service.controlStartRecording()
        result = .null
      case ControlMethods.stopRecording:
        try service.controlStopRecording()
        result = .null
      case ControlMethods.startHIDCapture:
        try requireNoParameters(request.params)
        try await service.controlStartHIDCapture()
        result = .null
      case ControlMethods.stopHIDCapture:
        try requireNoParameters(request.params)
        try await service.controlStopHIDCapture()
        result = .null
      default:
        return JSONRPCResponse(
          id: id,
          error: JSONRPCError(code: -32_601, message: "method not found")
        )
      }
      return JSONRPCResponse(id: id, result: result)
    } catch is DecodingError {
      return JSONRPCResponse(
        id: id,
        error: JSONRPCError(code: -32_602, message: "invalid params")
      )
    } catch let error as ControlProtocolError {
      return JSONRPCResponse(
        id: id,
        error: JSONRPCError(code: -32_602, message: String(describing: error))
      )
    } catch {
      return JSONRPCResponse(
        id: id,
        error: JSONRPCError(code: -32_000, message: String(describing: error))
      )
    }
  }

  private static func requireNoParameters(_ params: JSONValue?) throws {
    guard params == nil || params == .null else {
      throw ControlProtocolError.invalidParams("method accepts no parameters")
    }
  }
}
