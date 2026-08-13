import Dispatch
import Foundation
import MicFlurryAudio
import Testing

private struct AudioFixtures: Decodable {
  struct Resampling: Decodable {
    let inputRate: UInt32
    let outputRate: UInt32
    let blocks: [[Int16]]
    let expected: [Float]
  }

  let resampling: [Resampling]
}

private func loadAudioFixtures() throws -> AudioFixtures {
  let testFile = URL(fileURLWithPath: #filePath)
  let fixture =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/audio-core.json")
  return try JSONDecoder().decode(AudioFixtures.self, from: Data(contentsOf: fixture))
}

@Test func resamplingFixturesMatchAcceptedBehavior() throws {
  for fixture in try loadAudioFixtures().resampling {
    var resampler = LinearResampler(
      inputRate: fixture.inputRate,
      outputRate: fixture.outputRate
    )
    let actual = fixture.blocks.flatMap { resampler.process($0) }
    #expect(actual.count == fixture.expected.count)
    for (actual, expected) in zip(actual, fixture.expected) {
      #expect(abs(actual - expected) < 0.000_001)
    }
  }
}

@Test func resamplesAcrossBlockBoundaries() {
  var resampler = LinearResampler(inputRate: 8_000, outputRate: 16_000)
  var output = resampler.process([0, 10_000])
  output.append(contentsOf: resampler.process([20_000]))
  #expect(output.count == 5)
  #expect(abs(output[3] - 15_000 / 32_768) < 0.0001)
}

@Test func downsampleCountIsStable() {
  var resampler = LinearResampler(inputRate: 16_000, outputRate: 8_000)
  #expect(resampler.process(Array(repeating: 0, count: 160)).count == 80)
}

@Test func appliesGainClippingAndLevelFloor() {
  var samples: [Float] = [0.1, -0.1, 0.5]
  AudioProcessing.applyGain(&samples, decibels: 20)
  #expect(samples == [1, -1, 1])
  #expect(AudioProcessing.peakLevelDBFS([0, 0]) == -96)
  #expect(abs(AudioProcessing.peakLevelDBFS([0.5]) - -6.0206) < 0.001)
}

@Test func ringBufferWrapsDropsAndZeroFillsWithoutAllocationAtReadBoundary() {
  let ring = SPSCRingBuffer(capacity: 4)
  let first: [Float] = [1, 2, 3]
  #expect(first.withUnsafeBufferPointer { ring.write($0) } == 3)

  var output = Array(repeating: Float.nan, count: 2)
  #expect(output.withUnsafeMutableBufferPointer { ring.read(into: $0) } == 2)
  #expect(output == [1, 2])

  let second: [Float] = [4, 5, 6, 7]
  #expect(second.withUnsafeBufferPointer { ring.write($0) } == 3)
  #expect(ring.droppedSamples == 1)

  output = Array(repeating: Float.nan, count: 5)
  #expect(output.withUnsafeMutableBufferPointer { ring.read(into: $0) } == 4)
  #expect(output == [3, 4, 5, 6, 0])
  #expect(ring.availableSamples == 0)
}

@Test func ringBufferPreservesOrderAcrossConcurrentProducerAndConsumer() {
  let ring = SPSCRingBuffer(capacity: 64)
  let source = (0..<10_000).map(Float.init)
  let producerFinished = DispatchSemaphore(value: 0)

  DispatchQueue.global().async {
    source.withUnsafeBufferPointer { sourceBuffer in
      var position = 0
      while position < sourceBuffer.count {
        let end = min(sourceBuffer.count, position + 17)
        let batch = UnsafeBufferPointer(rebasing: sourceBuffer[position..<end])
        while ring.capacity - ring.availableSamples < batch.count {}
        position += ring.write(batch)
      }
    }
    producerFinished.signal()
  }

  var collected: [Float] = []
  collected.reserveCapacity(source.count)
  var renderBuffer = Array(repeating: Float.zero, count: 13)
  while collected.count < source.count {
    let consumed = renderBuffer.withUnsafeMutableBufferPointer { ring.read(into: $0) }
    collected.append(contentsOf: renderBuffer.prefix(consumed))
  }
  producerFinished.wait()

  #expect(collected == source)
  #expect(ring.droppedSamples == 0)
}

@Test func writesMonoIEEEFloatWAV() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let fileURL = directory.appendingPathComponent("test.wav")
  let recording = try Float32WAVRecording(fileURL: fileURL, sampleRate: 16_000)
  try recording.write([0.25, -0.5])
  let finished = try recording.finish()
  let data = try Data(contentsOf: fileURL)

  #expect(finished.sampleCount == 2)
  #expect(data.count == 52)
  #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
  #expect(data.littleEndianUInt16(at: 20) == 3)
  #expect(data.littleEndianUInt16(at: 22) == 1)
  #expect(data.littleEndianUInt32(at: 24) == 16_000)
  #expect(data.littleEndianUInt32(at: 40) == 8)
  #expect(Float(bitPattern: data.littleEndianUInt32(at: 44)) == 0.25)
  #expect(Float(bitPattern: data.littleEndianUInt32(at: 48)) == -0.5)
}

extension Data {
  fileprivate func littleEndianUInt16(at offset: Int) -> UInt16 {
    UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
  }

  fileprivate func littleEndianUInt32(at offset: Int) -> UInt32 {
    UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16
      | UInt32(self[offset + 3]) << 24
  }
}
