import Foundation

public enum ATVV {
  public static let serviceUUID = UUID(uuidString: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")!
  public static let transmitUUID = UUID(uuidString: "AB5E0002-5A21-4F05-BC7D-AF01F617B664")!
  public static let audioUUID = UUID(uuidString: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")!
  public static let controlUUID = UUID(uuidString: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")!

  public static let getCapabilities: [UInt8] = [0x0a, 0x01, 0x00, 0x00, 0x03, 0x03]
  public static let microphoneOpen: [UInt8] = [0x0c, 0x00]
  public static let microphoneCloseAny: [UInt8] = [0x0d, 0xff]

  public static func microphoneClose(streamID: UInt8) -> [UInt8] { [0x0d, streamID] }
  public static func microphoneExtend(streamID: UInt8) -> [UInt8] { [0x0e, streamID] }
}

public enum ATVVCodec: UInt8, Equatable, Sendable {
  case adpcm8kHz = 0x01
  case adpcm16kHz = 0x02

  public var sampleRate: UInt32 {
    switch self {
    case .adpcm8kHz: 8_000
    case .adpcm16kHz: 16_000
    }
  }
}

public enum ATVVControlMessage: Equatable, Sendable {
  case audioStop(reason: UInt8)
  case audioStart(reason: UInt8, codec: ATVVCodec, streamID: UInt8)
  case startSearch
  case audioSync(codec: ATVVCodec, frame: UInt16, predictor: Int16, stepIndex: UInt8)
  case capabilities(
    version: UInt16,
    codecs: UInt8,
    interactionModel: UInt8,
    frameSize: UInt16,
    extraConfiguration: UInt8,
    reserved: UInt8,
    firmwareData: [UInt8]
  )
  case microphoneOpenError(code: UInt16)
  case unknown(command: UInt8, payload: [UInt8])
}

public enum ATVVProtocolError: Error, Equatable, Sendable {
  case empty
  case tooShort(command: UInt8, needed: Int, actual: Int)
  case unsupportedCodec(UInt8)
  case invalidStepIndex(UInt8)
}

public enum ATVVControlParser {
  public static func parse(_ bytes: [UInt8]) throws -> ATVVControlMessage {
    guard let command = bytes.first else { throw ATVVProtocolError.empty }

    func payload(_ count: Int) throws -> ArraySlice<UInt8> {
      guard bytes.count >= count + 1 else {
        throw ATVVProtocolError.tooShort(
          command: command,
          needed: count,
          actual: max(0, bytes.count - 1)
        )
      }
      return bytes[1...count]
    }

    func codec(_ value: UInt8) throws -> ATVVCodec {
      guard let codec = ATVVCodec(rawValue: value) else {
        throw ATVVProtocolError.unsupportedCodec(value)
      }
      return codec
    }

    switch command {
    case 0x00:
      let data = try payload(1)
      return .audioStop(reason: data[data.startIndex])
    case 0x04:
      let data = Array(try payload(3))
      return .audioStart(reason: data[0], codec: try codec(data[1]), streamID: data[2])
    case 0x08:
      return .startSearch
    case 0x0a:
      let data = Array(try payload(6))
      return .audioSync(
        codec: try codec(data[0]),
        frame: UInt16(data[1]) << 8 | UInt16(data[2]),
        predictor: Int16(bitPattern: UInt16(data[3]) << 8 | UInt16(data[4])),
        stepIndex: data[5]
      )
    case 0x0b:
      let data = Array(try payload(8))
      return .capabilities(
        version: UInt16(data[0]) << 8 | UInt16(data[1]),
        codecs: data[2],
        interactionModel: data[3],
        frameSize: UInt16(data[4]) << 8 | UInt16(data[5]),
        extraConfiguration: data[6],
        reserved: data[7],
        firmwareData: Array(bytes.dropFirst(9))
      )
    case 0x0c:
      let data = Array(try payload(2))
      return .microphoneOpenError(code: UInt16(data[0]) << 8 | UInt16(data[1]))
    default:
      return .unknown(command: command, payload: Array(bytes.dropFirst()))
    }
  }
}

public struct IMAADPCMDecoder: Sendable {
  private var predictor: Int32 = 0
  private var stepIndex = 0

  public init() {}

  public mutating func synchronize(predictor: Int16, stepIndex: UInt8) throws {
    guard Int(stepIndex) < Self.stepTable.count else {
      throw ATVVProtocolError.invalidStepIndex(stepIndex)
    }
    self.predictor = Int32(predictor)
    self.stepIndex = Int(stepIndex)
  }

  public mutating func reset() {
    predictor = 0
    stepIndex = 0
  }

  public mutating func decode(_ encoded: [UInt8]) -> [Int16] {
    var output: [Int16] = []
    output.reserveCapacity(encoded.count * 2)
    for byte in encoded {
      output.append(decodeNibble(byte >> 4))
      output.append(decodeNibble(byte & 0x0f))
    }
    return output
  }

  private mutating func decodeNibble(_ nibble: UInt8) -> Int16 {
    let step = Self.stepTable[stepIndex]
    var difference = step >> 3
    if nibble & 0x04 != 0 { difference += step }
    if nibble & 0x02 != 0 { difference += step >> 1 }
    if nibble & 0x01 != 0 { difference += step >> 2 }
    predictor += nibble & 0x08 == 0 ? difference : -difference
    predictor = min(Int32(Int16.max), max(Int32(Int16.min), predictor))
    stepIndex = min(88, max(0, stepIndex + Self.indexTable[Int(nibble)]))
    return Int16(predictor)
  }

  private static let indexTable = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]
  private static let stepTable: [Int32] = [
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
    253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
    1_060, 1_166, 1_282, 1_411, 1_552, 1_707, 1_878, 2_066, 2_272, 2_499,
    2_749, 3_024, 3_327, 3_660, 4_026, 4_428, 4_871, 5_358, 5_894, 6_484,
    7_132, 7_845, 8_630, 9_493, 10_442, 11_487, 12_635, 13_899, 15_289, 16_818,
    18_500, 20_350, 22_385, 24_623, 27_086, 29_794, 32_767,
  ]
}

public enum ATVVFrameCounter {
  public static func signedDelta(actual: UInt16, expected: UInt16) -> Int32 {
    Int32(Int16(bitPattern: actual &- expected))
  }
}

public enum ATVVSessionLimit {
  public static let milliseconds: UInt64 = 60_000

  public static func boundedDuration(milliseconds: UInt64) -> UInt64 {
    min(milliseconds, Self.milliseconds)
  }
}
