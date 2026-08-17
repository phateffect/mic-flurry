import Foundation
import MicFlurryATVV
import MicFlurryAudio
import MicFlurryBluetooth
import MicFlurryControl
import MicFlurryDomain
import MicFlurryHIDClient
import MicFlurryHIDProtocol
import MicFlurryKeymap
import MicFlurryStorage

public typealias AudioSinkFactory = @MainActor @Sendable (Settings) throws -> any AudioSink

public enum DaemonRuntimeError: Error, Equatable, Sendable {
  case cannotReconfigureAudioWhileRecording
  case hidHelperUnavailable
  case noConnectedPhysicalDevice
  case unsupportedRemoteFingerprint
  case keymapUnavailable
  case keymapManagedByConfigurationFile
}

@MainActor
public final class DaemonRuntime {
  public private(set) var status: Status
  public private(set) var settings: Settings
  public let events: AsyncStream<Event>

  private let eventContinuation: AsyncStream<Event>.Continuation
  private let store: Store
  private let keymapStore: KeymapFileStore
  private let legacyActionChords: [String: String]
  private let bluetooth: any BluetoothTransport
  private let hidClient: HIDHelperClient?
  private let audioSinkFactory: AudioSinkFactory
  private let keyChords: any KeyChordPosting
  private var keyboardOutputSequence: UInt64 = 0
  private var heldDictationChord: KeyChord?
  private var keymapConfiguration: KeymapConfiguration?
  private var keymapStates: [KeyboardAction: KeymapGestureState] = [:]
  private var keymapOutputTask: Task<Void, Never>?
  private var keymapGeneration: UInt64 = 0
  private var audioSink: any AudioSink
  private var session = ATVVSession()
  private var resampler: LinearResampler
  private var recording: Float32WAVRecording?
  private var sessionStartedAt: ContinuousClock.Instant?
  private var eventTask: Task<Void, Never>?
  private var maintenanceTask: Task<Void, Never>?
  private var hidEventTask: Task<Void, Never>?
  private var autoReconnectEnabled = true
  private var hidCaptureDesired = false
  private var maintenanceTicks: UInt64 = 0
  private let clock = ContinuousClock()

  public init(
    databaseURL: URL,
    keymapDirectory: URL? = nil,
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
    keymapStore = KeymapFileStore(
      directory: keymapDirectory
        ?? databaseURL.deletingLastPathComponent().appendingPathComponent("keymaps")
    )
    var loadedSettings = try store.settings()
    legacyActionChords = loadedSettings.actionChords
    loadedSettings.actionChords = [:]
    settings = loadedSettings
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
    guard var device = status.devices.first(where: { $0.id == deviceID }),
      device.support.model != nil
    else { throw BluetoothAdapterError.unsupportedDevice(deviceID) }
    autoReconnectEnabled = true
    status.attaching = true
    publishStatus()
    do {
      var keymapError: String?
      let info = try await bluetooth.attach(to: deviceID)
      guard let remoteProfile = RemoteCatalog.profile(deviceInfo: info) else {
        try? await bluetooth.release()
        throw DaemonRuntimeError.unsupportedRemoteFingerprint
      }
      do {
        keymapConfiguration = try keymapStore.loadOrMigrate(
          model: remoteProfile.model,
          legacyActionChords: legacyActionChords
        )
      } catch {
        keymapConfiguration = nil
        keymapError = "Keymap unavailable: \(error)"
      }
      status.connectedDevice = deviceID
      status.deviceInfo = info
      device.support = .supported(model: remoteProfile.model)
      if let index = status.devices.firstIndex(where: { $0.id == deviceID }) {
        status.devices[index].support = device.support
      }
      status.attaching = false
      status.lastError = keymapError
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
    hidCaptureDesired = false
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
    cancelKeymapActivity()
    keymapConfiguration = nil
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
    guard let remoteProfile = status.deviceInfo.flatMap(RemoteCatalog.profile(deviceInfo:)) else {
      throw DaemonRuntimeError.unsupportedRemoteFingerprint
    }
    guard keymapConfiguration?.model == remoteProfile.model else {
      throw DaemonRuntimeError.keymapUnavailable
    }
    do {
      try await hidClient.startCapture(
        profileID: remoteProfile.hidProfileID,
        physicalDeviceID: physicalDeviceID
      )
      status.hid.mode = .seize
      status.hid.active = true
      status.hid.lastError = nil
      hidCaptureDesired = true
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
    hidCaptureDesired = false
    try await hidClient.stopCapture()
    cancelKeymapActivity()
    status.hid.active = false
    status.hid.mode = .monitor
    status.hid.lastError = nil
    publishStatus()
  }

  public func reloadKeymap() throws {
    guard let remoteProfile = status.deviceInfo.flatMap(RemoteCatalog.profile(deviceInfo:)) else {
      throw DaemonRuntimeError.unsupportedRemoteFingerprint
    }
    do {
      let candidate = try keymapStore.load(model: remoteProfile.model)
      cancelKeymapActivity()
      keymapConfiguration = candidate
      status.lastError = nil
      publishStatus()
    } catch {
      status.lastError = "Keymap reload failed: \(error)"
      publishStatus()
      throw error
    }
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
        cancelKeymapActivity()
        keymapConfiguration = nil
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

  @discardableResult
  private func postChord(
    _ chord: KeyChord, source: KeyboardSource, action: KeyboardAction, hold: Bool? = nil
  ) -> Bool {
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
    return succeeded
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
      if let action = input.mappedAction { handleKeymap(action: action, pressed: input.pressed) }
    case .stopped(let reason):
      cancelKeymapActivity()
      status.hid.active = false
      status.hid.mode = .monitor
      status.hid.lastError = reason == "explicit_stop" ? nil : reason
      publishStatus()
    case .interrupted:
      cancelKeymapActivity()
      status.hid.active = false
      status.hid.lastError = "HID helper interrupted"
      publishStatus()
    case .invalidated:
      cancelKeymapActivity()
      status.hid.active = false
      status.hid.lastError = "HID helper unavailable"
      publishStatus()
    }
  }

  private func handleKeymap(action: KeyboardAction, pressed: Bool) {
    guard let configuration = keymapConfiguration,
      let binding = configuration.bindings[action]
    else { return }
    let state = keymapStates[action] ?? KeymapGestureState()
    keymapStates[action] = state
    if pressed {
      guard !state.pressed else { return }
      state.pressed = true
      state.holdTriggered = false
      state.pressGeneration &+= 1
      let pressGeneration = state.pressGeneration
      state.holdTask?.cancel()
      if binding.doubleClick != nil, let pending = state.pendingClickTask {
        pending.cancel()
        state.pendingClickTask = nil
        state.completingDoubleClick = true
      }
      if let output = binding.hold {
        state.holdTask = Task { [weak self, weak state] in
          try? await Task.sleep(
            for: .milliseconds(Int(configuration.options.holdMilliseconds))
          )
          guard !Task.isCancelled, let self, let state, state.pressed,
            state.pressGeneration == pressGeneration
          else { return }
          state.holdTriggered = true
          state.pendingClickTask?.cancel()
          state.pendingClickTask = nil
          state.completingDoubleClick = false
          enqueue(output: output, action: action)
        }
      }
      return
    }

    guard state.pressed else { return }
    state.pressed = false
    state.holdTask?.cancel()
    state.holdTask = nil
    if state.holdTriggered {
      state.holdTriggered = false
      state.completingDoubleClick = false
      return
    }
    guard let doubleClick = binding.doubleClick else {
      if let click = binding.click { enqueue(output: click, action: action) }
      return
    }
    if state.completingDoubleClick {
      state.completingDoubleClick = false
      enqueue(output: doubleClick, action: action)
    } else {
      state.pendingClickTask = Task { [weak self, weak state] in
        try? await Task.sleep(
          for: .milliseconds(Int(configuration.options.doubleClickMilliseconds))
        )
        guard !Task.isCancelled, let self, let state else { return }
        state.pendingClickTask = nil
        if let click = binding.click { enqueue(output: click, action: action) }
      }
    }
  }

  private func enqueue(output: KeymapOutput, action: KeyboardAction) {
    guard case .chords(let chords) = output, !chords.isEmpty,
      let configuration = keymapConfiguration
    else { return }
    let previous = keymapOutputTask
    let generation = keymapGeneration
    let interval = configuration.options.sequenceIntervalMilliseconds
    keymapOutputTask = Task { [weak self] in
      if let previous { await previous.value }
      guard let self, generation == keymapGeneration else { return }
      for (index, chord) in chords.enumerated() {
        guard generation == keymapGeneration,
          postChord(chord, source: .hid, action: action)
        else { return }
        if index + 1 < chords.count, interval > 0 {
          try? await Task.sleep(for: .milliseconds(Int(interval)))
          guard !Task.isCancelled else { return }
        }
      }
    }
  }

  private func cancelKeymapActivity() {
    keymapGeneration &+= 1
    keymapOutputTask?.cancel()
    keymapOutputTask = nil
    for state in keymapStates.values {
      state.holdTask?.cancel()
      state.pendingClickTask?.cancel()
    }
    keymapStates.removeAll()
  }

  private func maintenanceTick() async {
    maintenanceTicks &+= 1
    if maintenanceTicks.isMultiple(of: 20) {
      await recoverBluetoothAttachmentIfNeeded()
      await recoverHIDCaptureIfNeeded()
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

  func recoverHIDCaptureIfNeeded() async {
    guard hidCaptureDesired, !status.hid.active, status.connectedDevice != nil,
      status.deviceInfo != nil, keymapConfiguration != nil
    else { return }
    try? await startHIDCapture()
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

@MainActor
private final class KeymapGestureState {
  var pressed = false
  var holdTriggered = false
  var completingDoubleClick = false
  var pressGeneration: UInt64 = 0
  var holdTask: Task<Void, Never>?
  var pendingClickTask: Task<Void, Never>?
}

extension DaemonRuntime: ControlService {
  public func controlStatus() -> Status {
    status
  }

  public func controlSettings() -> Settings {
    settings
  }

  public func controlSetSettings(_ change: SettingsChange) throws -> Settings {
    if change.actionChords != nil {
      throw DaemonRuntimeError.keymapManagedByConfigurationFile
    }
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

    let audioConfigurationChanged =
      candidate.injectionDeviceUID != settings.injectionDeviceUID
      || candidate.outputRateHz != settings.outputRateHz
    if recording != nil && audioConfigurationChanged {
      throw DaemonRuntimeError.cannotReconfigureAudioWhileRecording
    }
    let replacementSink = try audioConfigurationChanged ? audioSinkFactory(candidate) : nil
    settings = try store.updateSettings(change)
    settings.actionChords = [:]
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

  public func controlReloadKeymap() throws {
    try reloadKeymap()
  }
}
