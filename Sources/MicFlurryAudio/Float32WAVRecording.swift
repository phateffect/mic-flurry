import Foundation

public struct FinishedRecording: Equatable, Sendable {
  public let fileURL: URL
  public let startedAt: Date
  public let finishedAt: Date
  public let sampleCount: UInt64
  public let sampleRate: UInt32
}

public final class Float32WAVRecording {
  public let fileURL: URL
  public let startedAt: Date
  public let sampleRate: UInt32
  public private(set) var sampleCount: UInt64 = 0

  private var handle: FileHandle?

  public init(fileURL: URL, sampleRate: UInt32, startedAt: Date = Date()) throws {
    precondition(sampleRate > 0)
    self.fileURL = fileURL
    self.sampleRate = sampleRate
    self.startedAt = startedAt

    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: fileURL)
    self.handle = handle
    try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: 0))
  }

  deinit {
    try? handle?.close()
  }

  public static func create(
    in directory: URL,
    sampleRate: UInt32,
    now: Date = Date()
  ) throws -> Float32WAVRecording {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
    let fileURL = directory.appendingPathComponent("micflurry-\(formatter.string(from: now)).wav")
    return try Self(fileURL: fileURL, sampleRate: sampleRate, startedAt: now)
  }

  public func write(_ samples: [Float]) throws {
    guard let handle else { throw CocoaError(.fileWriteUnknown) }
    var data = Data(capacity: samples.count * MemoryLayout<UInt32>.size)
    for sample in samples {
      data.appendLittleEndian(sample.bitPattern)
    }
    try handle.write(contentsOf: data)
    sampleCount += UInt64(samples.count)
  }

  public func finish(at finishedAt: Date = Date()) throws -> FinishedRecording {
    guard let handle else { throw CocoaError(.fileWriteUnknown) }
    guard sampleCount <= UInt64((UInt32.max - 36) / 4) else {
      throw CocoaError(.fileWriteOutOfSpace)
    }
    let dataBytes = UInt32(sampleCount * 4)
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: dataBytes))
    try handle.close()
    self.handle = nil
    return FinishedRecording(
      fileURL: fileURL,
      startedAt: startedAt,
      finishedAt: finishedAt,
      sampleCount: sampleCount,
      sampleRate: sampleRate
    )
  }

  private static func header(sampleRate: UInt32, dataBytes: UInt32) -> Data {
    var data = Data()
    data.append(contentsOf: "RIFF".utf8)
    data.appendLittleEndian(36 + dataBytes)
    data.append(contentsOf: "WAVEfmt ".utf8)
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(3))  // IEEE Float
    data.appendLittleEndian(UInt16(1))  // mono
    data.appendLittleEndian(sampleRate)
    data.appendLittleEndian(sampleRate * 4)
    data.appendLittleEndian(UInt16(4))
    data.appendLittleEndian(UInt16(32))
    data.append(contentsOf: "data".utf8)
    data.appendLittleEndian(dataBytes)
    return data
  }
}

extension Data {
  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}
