import Foundation

public enum ATVVSessionAction: Equatable, Sendable {
  case writeCommand([UInt8])
  case audioStarted(rateHz: UInt32, streamID: UInt8)
  case audioStopped(reason: UInt8)
  case error(String)
}

public struct ATVVSessionState: Equatable, Sendable {
  public var active = false
  public var codec: ATVVCodec = .adpcm16kHz
  public var streamID: UInt8?
  public var lastStopReason: UInt8?
  public var protocolVersion: UInt16?
  public var negotiatedCodecs: UInt8?
  public var interactionModel: UInt8?
  public var frameSize: UInt16?
  public var extraConfiguration: UInt8?
  public var notificationCount: UInt64 = 0
  public var notificationBytes: UInt64 = 0
  public var notificationSizes: [UInt32: UInt64] = [:]
  public var decodedSamples: UInt64 = 0
  public var audioSyncCount: UInt64 = 0
  public var lastSyncFrame: UInt16?
  public var lastSyncGapFrames: Int32?
  public var injectedNotificationDrops: UInt64 = 0
  public var microphoneExtendsSent: UInt64 = 0

  public init() {}
}

public struct ATVVSession: Sendable {
  public private(set) var state = ATVVSessionState()

  private var decoder = IMAADPCMDecoder()
  private var nextAudioFrame: UInt16?

  public init() {}

  public mutating func handleControl(_ message: ATVVControlMessage) throws -> [ATVVSessionAction] {
    switch message {
    case .audioStart(_, let codec, let streamID):
      decoder.reset()
      state.active = true
      state.codec = codec
      state.streamID = streamID
      state.lastStopReason = nil
      state.notificationCount = 0
      state.notificationBytes = 0
      state.notificationSizes = [:]
      state.decodedSamples = 0
      state.audioSyncCount = 0
      state.lastSyncFrame = nil
      state.lastSyncGapFrames = nil
      state.injectedNotificationDrops = 0
      state.microphoneExtendsSent = 0
      nextAudioFrame = nil
      return [.audioStarted(rateHz: codec.sampleRate, streamID: streamID)]

    case .audioSync(let codec, let frame, let predictor, let stepIndex):
      try decoder.synchronize(predictor: predictor, stepIndex: stepIndex)
      state.codec = codec
      state.audioSyncCount += 1
      state.lastSyncFrame = frame
      state.lastSyncGapFrames = nextAudioFrame.map {
        ATVVFrameCounter.signedDelta(actual: frame, expected: $0)
      }
      nextAudioFrame = frame
      return []

    case .audioStop(let reason):
      let wasActive = state.active
      state.active = false
      state.streamID = nil
      state.lastStopReason = reason
      nextAudioFrame = nil
      return wasActive ? [.audioStopped(reason: reason)] : []

    case .startSearch:
      return [.writeCommand(ATVV.microphoneOpen)]

    case .capabilities(
      let version, let codecs, let interactionModel, let frameSize, let extra, _, _):
      state.protocolVersion = version
      state.negotiatedCodecs = codecs
      state.interactionModel = interactionModel
      state.frameSize = frameSize
      state.extraConfiguration = extra
      return []

    case .microphoneOpenError(let code):
      return [.error(String(format: "ATVV remote rejected microphone open: 0x%04x", code))]

    case .unknown:
      return []
    }
  }

  public mutating func handleAudio(
    _ bytes: [UInt8],
    dropNotification: UInt64? = nil
  ) -> [Int16]? {
    guard state.active else { return nil }
    state.notificationCount += 1
    state.notificationBytes += UInt64(bytes.count)
    state.notificationSizes[UInt32(clamping: bytes.count), default: 0] += 1
    if dropNotification == state.notificationCount {
      state.injectedNotificationDrops += 1
      return nil
    }
    if let frame = nextAudioFrame {
      nextAudioFrame = frame &+ 1
    }
    let samples = decoder.decode(bytes)
    state.decodedSamples += UInt64(samples.count)
    return samples
  }

  public mutating func extendActiveStream() -> ATVVSessionAction? {
    guard let streamID = state.streamID else { return nil }
    state.microphoneExtendsSent += 1
    return .writeCommand(ATVV.microphoneExtend(streamID: streamID))
  }

  public mutating func enforceHostCutoff(elapsedMilliseconds: UInt64) -> [ATVVSessionAction] {
    guard elapsedMilliseconds >= ATVVSessionLimit.milliseconds,
      let streamID = state.streamID
    else { return [] }
    state.active = false
    state.streamID = nil
    state.lastStopReason = 0
    nextAudioFrame = nil
    return [
      .writeCommand(ATVV.microphoneClose(streamID: streamID)),
      .audioStopped(reason: 0),
    ]
  }
}
