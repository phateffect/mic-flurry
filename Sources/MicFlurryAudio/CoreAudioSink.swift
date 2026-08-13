import AudioToolbox
import CoreAudio
import Foundation

public enum CoreAudioSinkError: Error, Equatable, Sendable {
  case deviceNotFound(String)
  case audioUnitUnavailable
  case osStatus(operation: String, status: OSStatus)
}

public protocol AudioSink: AnyObject, Sendable {
  var droppedSamples: UInt64 { get }
  @discardableResult func push(_ samples: [Float]) -> Int
}

public final class DisconnectedAudioSink: AudioSink, @unchecked Sendable {
  public private(set) var droppedSamples: UInt64 = 0

  public init() {}

  @discardableResult
  public func push(_ samples: [Float]) -> Int {
    droppedSamples += UInt64(samples.count)
    return 0
  }
}

public final class CoreAudioSink: AudioSink, @unchecked Sendable {
  public var droppedSamples: UInt64 { context.ring.droppedSamples }

  private let audioUnit: AudioUnit
  private let context: RenderContext

  public init(deviceUID: String, sampleRate: UInt32) throws {
    let deviceID = try Self.deviceID(forUID: deviceUID)
    var description = AudioComponentDescription(
      componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_HALOutput,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0,
      componentFlagsMask: 0
    )
    guard let component = AudioComponentFindNext(nil, &description) else {
      throw CoreAudioSinkError.audioUnitUnavailable
    }
    var createdUnit: AudioUnit?
    try Self.check(
      AudioComponentInstanceNew(component, &createdUnit),
      operation: "create AUHAL output"
    )
    guard let unit = createdUnit else { throw CoreAudioSinkError.audioUnitUnavailable }
    var initialized = false
    do {
      var inputEnabled: UInt32 = 0
      var outputEnabled: UInt32 = 1
      try Self.setProperty(
        unit,
        id: kAudioOutputUnitProperty_EnableIO,
        scope: kAudioUnitScope_Input,
        element: 1,
        value: &inputEnabled,
        operation: "disable AUHAL input"
      )
      try Self.setProperty(
        unit,
        id: kAudioOutputUnitProperty_EnableIO,
        scope: kAudioUnitScope_Output,
        element: 0,
        value: &outputEnabled,
        operation: "enable AUHAL output"
      )
      var mutableDeviceID = deviceID
      try Self.setProperty(
        unit,
        id: kAudioOutputUnitProperty_CurrentDevice,
        scope: kAudioUnitScope_Global,
        element: 0,
        value: &mutableDeviceID,
        operation: "select CoreAudio output device"
      )
      var format = AudioStreamBasicDescription(
        mSampleRate: Float64(sampleRate),
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
          | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0
      )
      try Self.setProperty(
        unit,
        id: kAudioUnitProperty_StreamFormat,
        scope: kAudioUnitScope_Input,
        element: 0,
        value: &format,
        operation: "set AUHAL Float32 mono stream format"
      )

      let context = RenderContext(capacity: max(1, Int(sampleRate) / 2))
      var callback = AURenderCallbackStruct(
        inputProc: coreAudioRenderCallback,
        inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
      )
      try Self.setProperty(
        unit,
        id: kAudioUnitProperty_SetRenderCallback,
        scope: kAudioUnitScope_Input,
        element: 0,
        value: &callback,
        operation: "install AUHAL render callback"
      )
      try Self.check(AudioUnitInitialize(unit), operation: "initialize AUHAL output")
      initialized = true
      try Self.check(AudioOutputUnitStart(unit), operation: "start AUHAL output")

      self.audioUnit = unit
      self.context = context
    } catch {
      if initialized { AudioUnitUninitialize(unit) }
      AudioComponentInstanceDispose(unit)
      throw error
    }
  }

  deinit {
    AudioOutputUnitStop(audioUnit)
    AudioUnitUninitialize(audioUnit)
    AudioComponentInstanceDispose(audioUnit)
  }

  @discardableResult
  public func push(_ samples: [Float]) -> Int {
    samples.withUnsafeBufferPointer { context.ring.write($0) }
  }

  public static func deviceID(forUID uid: String) throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var qualifier = uid as CFString
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        UInt32(MemoryLayout<CFString>.size),
        qualifierPointer,
        &size,
        &device
      )
    }
    try check(status, operation: "resolve CoreAudio device UID \(uid)")
    guard device != kAudioObjectUnknown else {
      throw CoreAudioSinkError.deviceNotFound(uid)
    }
    return device
  }

  private static func setProperty<T: BitwiseCopyable>(
    _ unit: AudioUnit,
    id: AudioUnitPropertyID,
    scope: AudioUnitScope,
    element: AudioUnitElement,
    value: inout T,
    operation: String
  ) throws {
    try check(
      AudioUnitSetProperty(
        unit,
        id,
        scope,
        element,
        &value,
        UInt32(MemoryLayout<T>.size)
      ),
      operation: operation
    )
  }

  private static func check(_ status: OSStatus, operation: String) throws {
    guard status == noErr else {
      throw CoreAudioSinkError.osStatus(operation: operation, status: status)
    }
  }
}

private final class RenderContext: @unchecked Sendable {
  let ring: SPSCRingBuffer

  init(capacity: Int) {
    ring = SPSCRingBuffer(capacity: capacity)
  }
}

private let coreAudioRenderCallback: AURenderCallback = {
  reference,
  _,
  _,
  _,
  frameCount,
  audioData in
  guard let audioData else { return noErr }
  let context = Unmanaged<RenderContext>.fromOpaque(reference).takeUnretainedValue()
  let buffers = UnsafeMutableAudioBufferListPointer(audioData)
  for index in buffers.indices {
    guard let data = buffers[index].mData else { continue }
    let availableFrames = Int(buffers[index].mDataByteSize) / MemoryLayout<Float>.size
    let count = min(Int(frameCount), availableFrames)
    let output = UnsafeMutableBufferPointer(
      start: data.assumingMemoryBound(to: Float.self),
      count: count
    )
    context.ring.read(into: output)
    buffers[index].mDataByteSize = UInt32(count * MemoryLayout<Float>.size)
  }
  return noErr
}
