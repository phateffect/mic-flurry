import Foundation
import MicFlurryATVV
import Testing

private struct Fixture: Decodable {
  struct Control: Decodable {
    let bytes: [UInt8]
    let expected: String
  }
  struct ADPCM: Decodable {
    let encoded: [UInt8]
    let expected: [Int16]
  }
  struct FrameDelta: Decodable {
    let actual: UInt16
    let expectedFrame: UInt16
    let delta: Int32
  }

  let control: [Control]
  let adpcm: [ADPCM]
  let frameDeltas: [FrameDelta]
}

private func loadFixture() throws -> Fixture {
  let testFile = URL(fileURLWithPath: #filePath)
  let fixture =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/atvv-v1.json")
  return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixture))
}

private func hex(_ bytes: [UInt8]) -> String {
  bytes.map { String(format: "%02x", $0) }.joined()
}

private func canonical(_ message: ATVVControlMessage) -> String {
  switch message {
  case .audioStop(let reason):
    "audio_stop:\(reason)"
  case .audioStart(let reason, let codec, let streamID):
    "audio_start:\(reason):\(codec.rawValue):\(streamID)"
  case .startSearch:
    "start_search"
  case .audioSync(let codec, let frame, let predictor, let stepIndex):
    "audio_sync:\(codec.rawValue):\(frame):\(predictor):\(stepIndex)"
  case .capabilities(
    let version, let codecs, let interactionModel, let frameSize, let extra, let reserved,
    let firmware):
    "capabilities:\(version):\(codecs):\(interactionModel):\(frameSize):\(extra):\(reserved):\(hex(firmware))"
  case .microphoneOpenError(let code):
    "mic_open_error:\(code)"
  case .unknown(let command, let payload):
    "unknown:\(command):\(hex(payload))"
  }
}

@Test func controlFixturesMatchAcceptedBehavior() throws {
  for item in try loadFixture().control {
    #expect(canonical(try ATVVControlParser.parse(item.bytes)) == item.expected)
  }
}

@Test func adpcmFixturesMatchAcceptedBehavior() throws {
  for item in try loadFixture().adpcm {
    var decoder = IMAADPCMDecoder()
    #expect(decoder.decode(item.encoded) == item.expected)
  }
}

@Test func frameDeltaFixturesMatchAcceptedBehavior() throws {
  for item in try loadFixture().frameDeltas {
    #expect(
      ATVVFrameCounter.signedDelta(actual: item.actual, expected: item.expectedFrame) == item.delta)
  }
}

@Test func rejectsMalformedMessagesAndDecoderState() {
  #expect(throws: ATVVProtocolError.tooShort(command: 0x04, needed: 3, actual: 1)) {
    try ATVVControlParser.parse([0x04, 0x01])
  }
  #expect(throws: ATVVProtocolError.invalidStepIndex(89)) {
    var decoder = IMAADPCMDecoder()
    try decoder.synchronize(predictor: 0, stepIndex: 89)
  }
}

@Test func everyTruncatedKnownControlPacketIsRejected() {
  let commandsAndPayloadSizes: [(UInt8, Int)] = [
    (0x00, 1), (0x04, 3), (0x0a, 6), (0x0b, 8), (0x0c, 2),
  ]
  for (command, requiredPayloadBytes) in commandsAndPayloadSizes {
    for actualPayloadBytes in 0..<requiredPayloadBytes {
      let packet = [command] + Array(repeating: UInt8(0), count: actualPayloadBytes)
      #expect(throws: ATVVProtocolError.self) {
        try ATVVControlParser.parse(packet)
      }
    }
  }

  for codec in UInt8.min...UInt8.max where ATVVCodec(rawValue: codec) == nil {
    #expect(throws: ATVVProtocolError.unsupportedCodec(codec)) {
      try ATVVControlParser.parse([0x04, 0, codec, 1])
    }
    #expect(throws: ATVVProtocolError.unsupportedCodec(codec)) {
      try ATVVControlParser.parse([0x0a, codec, 0, 0, 0, 0, 0])
    }
  }
}

@Test func buildsCommandsForNegotiatedStream() {
  #expect(ATVV.microphoneExtend(streamID: 0x2a) == [0x0e, 0x2a])
  #expect(ATVV.microphoneClose(streamID: 0x2a) == [0x0d, 0x2a])
  #expect(ATVVSessionLimit.boundedDuration(milliseconds: 75_000) == 60_000)
}

@Test func sessionTracksInjectedLossSyncGapRateTransitionAndStreamCommands() throws {
  var session = ATVVSession()
  #expect(
    try session.handleControl(
      .audioStart(reason: 3, codec: .adpcm16kHz, streamID: 0x2a)
    ) == [.audioStarted(rateHz: 16_000, streamID: 0x2a)]
  )
  _ = try session.handleControl(
    .audioSync(codec: .adpcm16kHz, frame: 10, predictor: 0, stepIndex: 0)
  )
  #expect(session.handleAudio(Array(repeating: 0x17, count: 120))?.count == 240)
  #expect(session.handleAudio(Array(repeating: 0x28, count: 120), dropNotification: 2) == nil)
  _ = try session.handleControl(
    .audioSync(codec: .adpcm8kHz, frame: 12, predictor: 256, stepIndex: 8)
  )

  #expect(session.state.codec == .adpcm8kHz)
  #expect(session.state.notificationCount == 2)
  #expect(session.state.notificationBytes == 240)
  #expect(session.state.notificationSizes[120] == 2)
  #expect(session.state.injectedNotificationDrops == 1)
  #expect(session.state.audioSyncCount == 2)
  #expect(session.state.lastSyncGapFrames == 1)
  #expect(session.extendActiveStream() == .writeCommand([0x0e, 0x2a]))
}

@Test func sessionEnforcesHostCutoffWithNegotiatedStream() throws {
  var session = ATVVSession()
  _ = try session.handleControl(.audioStart(reason: 0, codec: .adpcm16kHz, streamID: 0x2a))
  #expect(session.enforceHostCutoff(elapsedMilliseconds: 59_999).isEmpty)
  #expect(
    session.enforceHostCutoff(elapsedMilliseconds: 60_000) == [
      .writeCommand([0x0d, 0x2a]), .audioStopped(reason: 0),
    ]
  )
  #expect(!session.state.active)
  #expect(session.state.streamID == nil)
  #expect(session.state.lastStopReason == 0)
}
