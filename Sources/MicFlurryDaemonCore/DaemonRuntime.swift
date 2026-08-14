import Foundation
import MicFlurryATVV
import MicFlurryAudio
import MicFlurryBluetooth
import MicFlurryControl
import MicFlurryDomain
import MicFlurryHIDClient
import MicFlurryHIDProtocol
import MicFlurryStorage

public typealias AudioSinkFactory = @MainActor @Sendable (Settings) throws -> any AudioSink

public enum DaemonRuntimeError: Error, Equatable, Sendable {
  case cannotReconfigureAudioWhileRecording
  case hidHelperUnavailable
  case noConnectedPhysicalDevice
}

@MainActor
public final class DaemonRuntime {
  public private(set) var status: Status
  public private(set) var settings: Settings
  public let events: AsyncStream<Event>

  private let eventContinuation: AsyncStream<Event>.Continuation
  private let store: Store
  private let bluetooth: any BluetoothTransport
  private let hidClient: HIDHelperClient?
  private let audioSinkFactory: AudioSinkFactory
  private let keyChords: any KeyChordPosting
  private var keyboardOutputSequence: UInt64 = 0
  private var heldDictationChord: KeyChord?
  private var audioSink: any AudioSink
  private var session = ATVVSession()
  private var resampler: LinearResampler
  private var recording: Float32WAVRecording?
  private var sessionStartedAt: ContinuousClock.Instant?
  private var eventTask: Task<Void, Never>?
  private var maintenanceTask: Task<Void, Never>?
  private var hidEventTask: Task<Void, Never>?
  private var autoReconnectEnabled = true
  private var maintenanceTicks: UInt64 = 0
  private let clock = ContinuousClock()

  public init(
    databaseURL: URL,
    bluetooth: any BluetoothTransport,
    hidClient: HIDHelperClient? = nil,
    audioSinkFactory: @escaping AudioSinkFactory = { settings in
      try CoreAudioSink(
        deviceUID: settings.injectionDeviceUID,
        sampleRate: settings.outputRateHz
      )
    },
    keyChords: any KeyChordPosting = CGEventKeyChordPoster()
  ) throws {
    store = try Store(path: databaseURL)
    settings = try store.settings()
    self.bluetooth = bluetooth
    self.hidClient = hidClient
    self.audioSinkFactory = audioSinkFactory
    self.keyChords = keyChords
    let stream = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(256))
    events = stream.stream
    eventContinuation = stream.continuation

    var initialStatus = Status()
    initialStatus.audio.outputRateHz = settings.outputRateHz
    do {
      audioSink = try audioSinkFactory(settings)
    } catch {
      audioSink = DisconnectedAudioSink()
      initialStatus.lastError = "CoreAudio unavailable: \(error)"
    }
    status = initialStatus
    resampler = LinearResampler(inputRate: 16_000, outputRate: settings.outputRateHz)
  }

  deinit {
    eventContinuation.finish()
  }

  public func start() {
    guard eventTask == nil else { return }
    let bluetoothEvents = bluetooth.events
    eventTask = Task { [weak self] in
      for await event in bluetoothEvents {
        guard let self else { return }
        await handleBluetoothEvent(event)
      }
    }
    maintenanceTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
        guard let self else { return }
        await maintenanceTick()
      }
    }
    if let hidClient {
      let hidEvents = hidClient.events
      hidEventTask = Task { [weak self] in
        var eventsSinceYield = 0
        for await event in hidEvents {
          guard let self else { return }
          handleHIDEvent(event)
          eventsSinceYield += 1
          if eventsSinceYield == 16 {
            eventsSinceYield = 0
            await Task.yield()
          }
        }
      }
    }
  }

  public func stop() async {
    eventTask?.cancel()
    maintenanceTask?.cancel()
    hidEventTask?.cancel()
    eventTask = nil
    maintenanceTask = nil
    hidEventTask = nil
    await hidClient?.shutdown()
    try? await release()
    eventContinuation.finish()
  }

  public func refreshDevices() async throws {
    status.bluetooth = .refreshing
    publishStatus()
    do {
      status.devices = try await bluetooth.connectedATVVDevices()
      for index in status.devices.indices {
        status.devices[index].known = try store.isKnown(deviceID: status.devices[index].id)
      }
      status.bluetooth = .idle
      publishStatus()
    } catch {
      status.bluetooth = .idle
      report(error)
      publishStatus()
      throw error
    }
  }

  public func connect(to deviceID: DeviceID) async throws {
    if status.connectedDevice == deviceID, status.deviceInfo != nil { return }
    guard let device = status.devices.first(where: { $0.id == deviceID }),
      device.support.model != nil
    else { throw BluetoothAdapterError.unsupportedDevice(deviceID) }
    autoReconnectEnabled = true
    status.attaching = true
    publishStatus()
    do {
      let info = try await bluetooth.attach(to: deviceID)
      status.connectedDevice = deviceID
      status.deviceInfo = info
      status.attaching = false
      status.lastError = nil
      for index in status.devices.indices {
        status.devices[index].connected = status.devices[index].id == deviceID
      }
      try store.rememberDevice(device)
      eventContinuation.yield(.connected(deviceID))
      publishStatus()
    } catch {
      status.attaching = false
      report(error)
      publishStatus()
      throw error
    }
  }

  public func release() async throws {
    autoReconnectEnabled = false
    try await releaseBluetoothAndLocalState()
  }

  private func releaseBluetoothAndLocalState() async throws {
    var firstError: (any Error)?
    if let streamID = session.state.streamID {
      do {
        try bluetooth.writeCommand(ATVV.microphoneClose(streamID: streamID))
      } catch {
        firstError = error
      }
    }
    do {
      try await bluetooth.release()
    } catch {
      if firstError == nil { firstError = error }
    }
    if recording != nil {
      do {
        try finishRecording()
      } catch {
        if firstError == nil { firstError = error }
      }
    }
    let connected = status.connectedDevice
    status.connectedDevice = nil
    status.deviceInfo = nil
    for index in status.devices.indices {
      status.devices[index].connected = false
    }
    status.audio.active = false
    status.audio.streamID = nil
    if session.state.active { postDictationKeys(start: false) }
    session = ATVVSession()
    sessionStartedAt = nil
    if let connected { eventContinuation.yield(.disconnected(connected)) }
    publishStatus()
    if let firstError { throw firstError }
  }

  public func startRecording() throws {
    guard recording == nil else { return }
    let directory = URL(fileURLWithPath: settings.recordingDirectory, isDirectory: true)
    let recording = try Float32WAVRecording.create(
      in: directory,
      sampleRate: settings.outputRateHz
    )
    self.recording = recording
    status.recording.active = true
    status.recording.path = recording.fileURL.path
    status.recording.sampleCount = 0
    eventContinuation.yield(.recordingStarted(path: recording.fileURL.path))
  }

  public func stopRecording() throws {
    if recording != nil { try finishRecording() }
  }

  public func startHIDCapture() async throws {
    guard let hidClient else { throw DaemonRuntimeError.hidHelperUnavailable }
    guard let physicalDeviceID = status.deviceInfo?.physicalDeviceID else {
      throw DaemonRuntimeError.noConnectedPhysicalDevice
    }
    do {
      try await hidClient.startCapture(
        profileID: "rc003-v1",
        physicalDeviceID: physicalDeviceID
      )
      status.hid.mode = .seize
      status.hid.active = true
      status.hid.lastError = nil
      publishStatus()
    } catch {
      status.hid.active = false
      status.hid.lastError = String(describing: error)
      publishStatus()
      throw error
    }
  }

  public func stopHIDCapture() async throws {
    guard let hidClient else { throw DaemonRuntimeError.hidHelperUnavailable }
    try await hidClient.stopCapture()
    status.hid.active = false
    status.hid.mode = .monitor
    status.hid.lastError = nil
    publishStatus()
  }

  func handleBluetoothEvent(_ event: BluetoothEvent) async {
    do {
      switch event {
      case .control(_, let bytes):
        let message = try ATVVControlParser.parse(bytes)
        let previousCodec = session.state.codec
        let actions = try session.handleControl(message)
        if session.state.codec != previousCodec {
          resampler.reconfigure(
            inputRate: session.state.codec.sampleRate,
            outputRate: settings.outputRateHz
          )
        }
        try process(actions)
        synchronizeStatus()

      case .audio(_, let bytes):
        guard let decoded = session.handleAudio(bytes) else { return }
        var samples = resampler.process(decoded)
        AudioProcessing.applyGain(&samples, decibels: settings.inputGainDB)
        status.audio.levelDBFS = AudioProcessing.peakLevelDBFS(samples)
        audioSink.push(samples)
        status.audio.droppedFrames = audioSink.droppedSamples
        if let recording {
          try recording.write(samples)
          status.recording.sampleCount = recording.sampleCount
        }
        synchronizeStatus(publish: false)

      case .disconnected(let deviceID):
        if recording != nil { try finishRecording() }
        status.connectedDevice = nil
        status.deviceInfo = nil
        for index in status.devices.indices where status.devices[index].id == deviceID {
          status.devices[index].connected = false
        }
        if session.state.active { postDictationKeys(start: false) }
        session = ATVVSession()
        sessionStartedAt = nil
        eventContinuation.yield(.disconnected(deviceID))
        synchronizeStatus()
      }
    } catch {
      report(error)
    }
  }

  private func process(_ actions: [ATVVSessionAction]) throws {
    for action in actions {
      switch action {
      case .writeCommand(let bytes):
        try bluetooth.writeCommand(bytes)
      case .audioStarted(let rateHz, _):
        sessionStartedAt = clock.now
        resampler.reconfigure(inputRate: rateHz, outputRate: settings.outputRateHz)
        postDictationKeys(start: true)
        if settings.autoRecord, recording == nil { try startRecording() }
        eventContinuation.yield(.audioStarted(rateHz: rateHz))
      case .audioStopped:
        sessionStartedAt = nil
        postDictationKeys(start: false)
        if settings.autoRecord, recording != nil { try finishRecording() }
        eventContinuation.yield(.audioStopped)
      case .error(let message):
        reportMessage(message)
      }
    }
  }

  private func postDictationKeys(start: Bool) {
    let tapMode = settings.dictationMode == "tap"
    if start {
      guard let chord = KeyChord(parsing: settings.dictationStartChord) else { return }
      if tapMode {
        postChord(chord, source: .audio, action: .dictationStart)
      } else {
        heldDictationChord = chord
        postChord(chord, source: .audio, action: .dictationStart, hold: true)
      }
    } else {
      if let held = heldDictationChord {
        heldDictationChord = nil
        postChord(held, source: .audio, action: .dictationEnd, hold: false)
      }
      if let chord = KeyChord(parsing: settings.dictationEndChord) {
        postChord(chord, source: .audio, action: .dictationEnd)
      }
    }
  }

  private func postChord(
    _ chord: KeyChord, source: KeyboardSource, action: KeyboardAction, hold: Bool? = nil
  ) {
    keyboardOutputSequence += 1
    let succeeded: Bool
    switch hold {
    case .some(true): succeeded = keyChords.holdChord(chord, down: true)
    case .some(false): succeeded = keyChords.holdChord(chord, down: false)
    case .none: succeeded = keyChords.postChord(chord)
    }
    eventContinuation.yield(
      .keyboardOutput(
        KeyboardOutput(
          sequence: keyboardOutputSequence,
          source: source,
          action: action,
          succeeded: succeeded,
          error: succeeded ? nil : "CGEvent post failed; grant Accessibility to MicFlurry"
        )))
  }

  private func handleHIDEvent(_ event: HIDHelperConnectionEvent) {
    switch event {
    case .capture(let event):
      let input: HIDInput
      switch event.kind {
      case .rawReport(_, let reportID, let bytes):
        input = HIDInput(
          sequence: event.sequence,
          interfaceIndex: event.interfaceIndex,
          usagePage: 0,
          usage: 0,
          usageName: "raw_report",
          value: 0,
          pressed: false,
          reportID: reportID,
          rawReport: [UInt8](bytes)
        )
      case .value(let usagePage, let usage, let value):
        input = HIDInput(
          sequence: event.sequence,
          interfaceIndex: event.interfaceIndex,
          usagePage: usagePage,
          usage: usage,
          usageName: String(format: "0x%04x/0x%08x", usagePage, usage),
          value: value,
          pressed: value != 0,
          mappedAction: HIDUsageMapping.keyboardAction(usagePage: usagePage, usage: usage)
        )
      }
      status.hid.recentInputs.append(input)
      if status.hid.recentInputs.count > 64 {
        status.hid.recentInputs.removeFirst(status.hid.recentInputs.count - 64)
      }
      eventContinuation.yield(.hidInput(input))
      if input.pressed, let action = input.mappedAction,
        let chordText = settings.actionChords[action.rawValue],
        let chord = KeyChord(parsing: chordText)
      {
        postChord(chord, source: .hid, action: action)
      }
    case .stopped(let reason):
      status.hid.active = false
      status.hid.mode = .monitor
      status.hid.lastError = reason == "explicit_stop" ? nil : reason
      publishStatus()
    case .interrupted:
      status.hid.active = false
      status.hid.lastError = "HID helper interrupted"
      publishStatus()
    case .invalidated:
      status.hid.active = false
      status.hid.lastError = "HID helper unavailable"
      publishStatus()
    }
  }

  private func maintenanceTick() async {
    maintenanceTicks &+= 1
    if maintenanceTicks.isMultiple(of: 20) {
      await recoverBluetoothAttachmentIfNeeded()
    }
    guard let sessionStartedAt else { return }
    let elapsed = sessionStartedAt.duration(to: clock.now)
    let milliseconds =
      UInt64(max(0, elapsed.components.seconds * 1_000))
      + UInt64(max(0, elapsed.components.attoseconds / 1_000_000_000_000_000))
    status.audio.sessionDurationMilliseconds = ATVVSessionLimit.boundedDuration(
      milliseconds: milliseconds)
    do {
      if milliseconds >= ATVVSessionLimit.milliseconds {
        try process(session.enforceHostCutoff(elapsedMilliseconds: milliseconds))
      } else {
        let requiredExtends = milliseconds / 10_000
        while session.state.microphoneExtendsSent < requiredExtends {
          if let action = session.extendActiveStream() { try process([action]) }
        }
      }
      synchronizeStatus()
    } catch {
      report(error)
    }
  }

  func recoverBluetoothAttachmentIfNeeded() async {
    guard autoReconnectEnabled, !status.attaching else { return }
    if status.connectedDevice != nil, bluetooth.attachedDeviceIsConnected() { return }

    if let disconnected = status.connectedDevice {
      try? await bluetooth.release()
      status.connectedDevice = nil
      status.deviceInfo = nil
      status.audio.active = false
      status.audio.streamID = nil
      if session.state.active { postDictationKeys(start: false) }
      session = ATVVSession()
      sessionStartedAt = nil
      for index in status.devices.indices {
        status.devices[index].connected = false
      }
      eventContinuation.yield(.disconnected(disconnected))
      publishStatus()
    }

    do {
      let devices = try await bluetooth.connectedATVVDevices()
      status.devices = devices
      for index in status.devices.indices {
        status.devices[index].known = try store.isKnown(deviceID: status.devices[index].id)
      }
      guard let preferred = try store.lastConnectedDeviceID(),
        status.devices.contains(where: { $0.id == preferred && $0.support.model != nil })
      else {
        publishStatus()
        return
      }
      try await connect(to: preferred)
    } catch {
      report(error)
      publishStatus()
    }
  }

  private func synchronizeStatus(publish: Bool = true) {
    let state = session.state
    status.audio.active = state.active
    status.audio.sourceRateHz = state.active ? state.codec.sampleRate : status.audio.sourceRateHz
    status.audio.streamID = state.streamID
    status.audio.lastStopReason = state.lastStopReason
    status.audio.protocolVersion = state.protocolVersion
    status.audio.negotiatedCodecs = state.negotiatedCodecs
    status.audio.interactionModel = state.interactionModel
    status.audio.frameSize = state.frameSize
    status.audio.extraConfiguration = state.extraConfiguration
    status.audio.notificationCount = state.notificationCount
    status.audio.notificationBytes = state.notificationBytes
    status.audio.notificationSizes = state.notificationSizes.keys.sorted().map {
      NotificationSizeCount(bytes: $0, count: state.notificationSizes[$0] ?? 0)
    }
    status.audio.decodedFrames = state.decodedSamples
    status.audio.audioSyncCount = state.audioSyncCount
    status.audio.lastSyncFrame = state.lastSyncFrame
    status.audio.lastSyncGapFrames = state.lastSyncGapFrames
    status.audio.injectedNotificationDrops = state.injectedNotificationDrops
    status.audio.microphoneExtendsSent = state.microphoneExtendsSent
    if publish { publishStatus() }
  }

  private func finishRecording() throws {
    guard let recording else { return }
    let finished = try recording.finish()
    self.recording = nil
    status.recording = RecordingStatus()
    try store.addRecording(
      path: finished.fileURL,
      deviceID: status.connectedDevice,
      sampleRate: finished.sampleRate,
      sampleCount: finished.sampleCount,
      startedAt: finished.startedAt,
      finishedAt: finished.finishedAt
    )
    eventContinuation.yield(
      .recordingStopped(path: finished.fileURL.path, sampleCount: finished.sampleCount)
    )
  }

  private func publishStatus() {
    eventContinuation.yield(.status(status))
  }

  private func report(_ error: any Error) {
    reportMessage(String(describing: error))
  }

  private func reportMessage(_ message: String) {
    status.lastError = message
    eventContinuation.yield(.error(message: message))
  }
}

extension DaemonRuntime: ControlService {
  public func controlStatus() -> Status {
    status
  }

  public func controlSettings() -> Settings {
    settings
  }

  public func controlSetSettings(_ change: SettingsChange) throws -> Settings {
    try SettingsValidator.validate(change)
    var candidate = settings
    if let value = change.injectionDeviceUID { candidate.injectionDeviceUID = value }
    if let value = change.outputRateHz { candidate.outputRateHz = value }
    if let value = change.inputGainDB { candidate.inputGainDB = value }
    if let value = change.recordingDirectory { candidate.recordingDirectory = value }
    if let value = change.autoRecord { candidate.autoRecord = value }
    if let value = change.dictationStartChord {
      candidate.dictationStartChord = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let value = change.dictationEndChord {
      candidate.dictationEndChord = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let value = change.dictationMode {
      candidate.dictationMode = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let value = change.actionChords { candidate.actionChords = value }

    let audioConfigurationChanged =
      candidate.injectionDeviceUID != settings.injectionDeviceUID
      || candidate.outputRateHz != settings.outputRateHz
    if recording != nil && audioConfigurationChanged {
      throw DaemonRuntimeError.cannotReconfigureAudioWhileRecording
    }
    let replacementSink = try audioConfigurationChanged ? audioSinkFactory(candidate) : nil
    settings = try store.updateSettings(change)
    if let replacementSink {
      audioSink = replacementSink
      resampler.reconfigure(
        inputRate: session.state.codec.sampleRate,
        outputRate: settings.outputRateHz
      )
      status.audio.outputRateHz = settings.outputRateHz
    }
    publishStatus()
    return settings
  }

  public func controlRefreshDevices() async throws {
    try await refreshDevices()
  }

  public func controlConnect(to deviceID: DeviceID) async throws {
    try await connect(to: deviceID)
  }

  public func controlRelease() async throws {
    try await release()
  }

  public func controlStartRecording() throws {
    try startRecording()
  }

  public func controlStopRecording() throws {
    try stopRecording()
  }

  public func controlStartHIDCapture() async throws {
    try await startHIDCapture()
  }

  public func controlStopHIDCapture() async throws {
    try await stopHIDCapture()
  }
}
