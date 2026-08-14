import Foundation

public struct DeviceID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public enum BluetoothState: String, Codable, Sendable {
  case idle
  case refreshing
  case unavailable
}

public enum DeviceSupport: Codable, Equatable, Sendable {
  case unsupported
  case supported(model: String)

  public var model: String? {
    guard case .supported(let model) = self else { return nil }
    return model
  }
}

public struct Device: Codable, Equatable, Sendable {
  public var id: DeviceID
  public var name: String
  public var rssi: Int16?
  public var known: Bool
  public var connected: Bool
  public var supportsATVV: Bool
  public var support: DeviceSupport

  public init(
    id: DeviceID,
    name: String,
    rssi: Int16? = nil,
    known: Bool = false,
    connected: Bool = false,
    supportsATVV: Bool = false,
    support: DeviceSupport = .unsupported
  ) {
    self.id = id
    self.name = name
    self.rssi = rssi
    self.known = known
    self.connected = connected
    self.supportsATVV = supportsATVV
    self.support = support
  }
}

public struct NotificationSizeCount: Codable, Equatable, Sendable {
  public var bytes: UInt32
  public var count: UInt64

  public init(bytes: UInt32, count: UInt64) {
    self.bytes = bytes
    self.count = count
  }
}

public struct AudioStatus: Codable, Equatable, Sendable {
  public var active = false
  public var sessionDurationMilliseconds: UInt64 = 0
  public var sourceRateHz: UInt32?
  public var outputRateHz: UInt32 = 48_000
  public var levelDBFS: Float?
  public var decodedFrames: UInt64 = 0
  public var droppedFrames: UInt64 = 0
  public var protocolVersion: UInt16?
  public var streamID: UInt8?
  public var microphoneExtendsSent: UInt64 = 0
  public var lastStopReason: UInt8?
  public var negotiatedCodecs: UInt8?
  public var interactionModel: UInt8?
  public var frameSize: UInt16?
  public var extraConfiguration: UInt8?
  public var notificationCount: UInt64 = 0
  public var notificationBytes: UInt64 = 0
  public var notificationSizes: [NotificationSizeCount] = []
  public var audioSyncCount: UInt64 = 0
  public var lastSyncFrame: UInt16?
  public var lastSyncGapFrames: Int32?
  public var injectedNotificationDrops: UInt64 = 0

  public init() {}
}

public struct DeviceInfo: Codable, Equatable, Sendable {
  public var attMTU: UInt16?
  public var manufacturerName: String?
  public var modelNumber: String?
  public var serialNumber: String?
  public var hardwareRevision: String?
  public var firmwareRevision: String?
  public var softwareRevision: String?
  public var hidManufacturer: String?
  public var hidProduct: String?
  public var hidVendorID: UInt32?
  public var hidProductID: UInt32?
  public var hidTransport: String?
  public var hidSerialNumber: String?
  public var hidVersionNumber: UInt32?
  public var physicalDeviceID: String?

  public init() {}
}

public enum KeyboardAction: String, Codable, CaseIterable, Sendable {
  case up
  case down
  case left
  case right
  case select
  case back
  case home
  case playPause = "play_pause"
  case previous
  case next
  case volumeDown = "volume_down"
  case volumeUp = "volume_up"
  case mute
  case dictationStart = "dictation_start"
  case dictationEnd = "dictation_end"
}

public enum HIDCaptureMode: String, Codable, Sendable {
  case monitor
  case seize
}

public struct HIDInput: Codable, Equatable, Sendable {
  public var sequence: UInt64
  public var interfaceIndex: UInt16?
  public var usagePage: UInt32
  public var usage: UInt32
  public var usageName: String
  public var value: Int64
  public var pressed: Bool
  public var mappedAction: KeyboardAction?
  public var reportID: UInt32?
  public var rawReport: [UInt8]?

  public init(
    sequence: UInt64,
    interfaceIndex: UInt16? = nil,
    usagePage: UInt32,
    usage: UInt32,
    usageName: String,
    value: Int64,
    pressed: Bool,
    mappedAction: KeyboardAction? = nil,
    reportID: UInt32? = nil,
    rawReport: [UInt8]? = nil
  ) {
    self.sequence = sequence
    self.interfaceIndex = interfaceIndex
    self.usagePage = usagePage
    self.usage = usage
    self.usageName = usageName
    self.value = value
    self.pressed = pressed
    self.mappedAction = mappedAction
    self.reportID = reportID
    self.rawReport = rawReport
  }
}

public enum KeyboardSource: String, Codable, Sendable {
  case tui
  case hid
  case audio
}

public struct KeyboardOutput: Codable, Equatable, Sendable {
  public var sequence: UInt64
  public var source: KeyboardSource
  public var action: KeyboardAction
  public var succeeded: Bool
  public var error: String?

  public init(
    sequence: UInt64,
    source: KeyboardSource,
    action: KeyboardAction,
    succeeded: Bool,
    error: String? = nil
  ) {
    self.sequence = sequence
    self.source = source
    self.action = action
    self.succeeded = succeeded
    self.error = error
  }
}

public struct HIDStatus: Codable, Equatable, Sendable {
  public var mode: HIDCaptureMode = .monitor
  public var active = false
  public var lastError: String?
  public var recentInputs: [HIDInput] = []
  public var recentOutputs: [KeyboardOutput] = []

  public init() {}
}

public struct RecordingStatus: Codable, Equatable, Sendable {
  public var active = false
  public var path: String?
  public var sampleCount: UInt64 = 0

  public init() {}
}

public struct Status: Codable, Equatable, Sendable {
  public var bluetooth: BluetoothState = .idle
  public var devices: [Device] = []
  public var connectedDevice: DeviceID?
  public var attaching = false
  public var deviceInfo: DeviceInfo?
  public var hid = HIDStatus()
  public var audio = AudioStatus()
  public var recording = RecordingStatus()
  public var lastError: String?

  public init() {}
}

public struct Settings: Codable, Equatable, Sendable {
  public var injectionDeviceUID: String
  public var outputRateHz: UInt32
  public var inputGainDB: Float
  public var recordingDirectory: String
  public var autoRecord: Bool
  public var dictationStartChord: String
  public var dictationEndChord: String
  /// "hold" keeps dictationStartChord pressed for the whole session;
  /// "tap" taps dictationStartChord at start and dictationEndChord at end.
  public var dictationMode: String
  /// HID action (KeyboardAction raw value, e.g. "volume_up") to key chord.
  /// An empty chord disables the mapping.
  public var actionChords: [String: String]

  public init(
    injectionDeviceUID: String = "MicFlurry_2_UID",
    outputRateHz: UInt32 = 48_000,
    inputGainDB: Float = 12,
    recordingDirectory: String,
    autoRecord: Bool = false,
    dictationStartChord: String = "fn",
    dictationEndChord: String = "",
    dictationMode: String = "hold",
    actionChords: [String: String] = [:]
  ) {
    self.injectionDeviceUID = injectionDeviceUID
    self.outputRateHz = outputRateHz
    self.inputGainDB = inputGainDB
    self.recordingDirectory = recordingDirectory
    self.autoRecord = autoRecord
    self.dictationStartChord = dictationStartChord
    self.dictationEndChord = dictationEndChord
    self.dictationMode = dictationMode
    self.actionChords = actionChords
  }
}

public struct SettingsChange: Codable, Equatable, Sendable {
  public var injectionDeviceUID: String?
  public var outputRateHz: UInt32?
  public var inputGainDB: Float?
  public var recordingDirectory: String?
  public var autoRecord: Bool?
  public var dictationStartChord: String?
  public var dictationEndChord: String?
  public var dictationMode: String?
  /// Replaces the whole action-to-chord map when present.
  public var actionChords: [String: String]?

  public init(
    injectionDeviceUID: String? = nil,
    outputRateHz: UInt32? = nil,
    inputGainDB: Float? = nil,
    recordingDirectory: String? = nil,
    autoRecord: Bool? = nil,
    dictationStartChord: String? = nil,
    dictationEndChord: String? = nil,
    dictationMode: String? = nil,
    actionChords: [String: String]? = nil
  ) {
    self.injectionDeviceUID = injectionDeviceUID
    self.outputRateHz = outputRateHz
    self.inputGainDB = inputGainDB
    self.recordingDirectory = recordingDirectory
    self.autoRecord = autoRecord
    self.dictationStartChord = dictationStartChord
    self.dictationEndChord = dictationEndChord
    self.dictationMode = dictationMode
    self.actionChords = actionChords
  }
}

public enum SettingsValidationError: Error, Equatable, Sendable {
  case emptyInjectionDeviceUID
  case unsupportedOutputRate(UInt32)
  case invalidInputGain(Float)
  case emptyRecordingDirectory
  case invalidKeyChord(String)
  case invalidDictationMode(String)
  case invalidChordAction(String)
}

public enum SettingsValidator {
  public static let supportedOutputRates: Set<UInt32> = [8_000, 16_000, 44_100, 48_000]
  public static let dictationModes: Set<String> = ["hold", "tap"]

  public static func validate(_ change: SettingsChange) throws {
    if let uid = change.injectionDeviceUID,
      uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw SettingsValidationError.emptyInjectionDeviceUID
    }
    if let rate = change.outputRateHz, !supportedOutputRates.contains(rate) {
      throw SettingsValidationError.unsupportedOutputRate(rate)
    }
    if let gain = change.inputGainDB, !gain.isFinite || !(-24...24).contains(gain) {
      throw SettingsValidationError.invalidInputGain(gain)
    }
    if let directory = change.recordingDirectory,
      directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw SettingsValidationError.emptyRecordingDirectory
    }
    for chord in [change.dictationStartChord, change.dictationEndChord] {
      if let chord {
        let trimmed = chord.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && KeyChord(parsing: trimmed) == nil {
          throw SettingsValidationError.invalidKeyChord(chord)
        }
      }
    }
    if let mode = change.dictationMode,
      !dictationModes.contains(mode.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      throw SettingsValidationError.invalidDictationMode(mode)
    }
    if let actionChords = change.actionChords {
      let actions = Set(KeyboardAction.allCases.map(\.rawValue))
      for (action, chord) in actionChords {
        guard actions.contains(action) else {
          throw SettingsValidationError.invalidChordAction(action)
        }
        let trimmed = chord.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && KeyChord(parsing: trimmed) == nil {
          throw SettingsValidationError.invalidKeyChord(chord)
        }
      }
    }
  }
}

public enum Event: Codable, Equatable, Sendable {
  case status(Status)
  case deviceDiscovered(Device)
  case attaching(device: DeviceID, active: Bool)
  case connected(DeviceID)
  case disconnected(DeviceID)
  case audioStarted(rateHz: UInt32)
  case audioLevel(dbfs: Float)
  case audioStopped
  case recordingStarted(path: String)
  case recordingStopped(path: String, sampleCount: UInt64)
  case hidInput(HIDInput)
  case keyboardOutput(KeyboardOutput)
  case error(message: String)
}

public enum HIDUsageMapping {
  public static func keyboardAction(usagePage: UInt32, usage: UInt32) -> KeyboardAction? {
    switch (usagePage, usage) {
    case (0x07, 0x28), (0x0c, 0x41): .select
    case (0x07, 0x29), (0x07, 0xf1), (0x0c, 0x46), (0x0c, 0x224): .back
    case (0x07, 0x4a), (0x0c, 0x223): .home
    case (0x07, 0x4f), (0x0c, 0x45): .right
    case (0x07, 0x50), (0x0c, 0x44): .left
    case (0x07, 0x51), (0x0c, 0x43): .down
    case (0x07, 0x52), (0x0c, 0x42): .up
    case (0x07, 0x2c), (0x0c, 0xb0), (0x0c, 0xb1), (0x0c, 0xcd): .playPause
    case (0x0c, 0xb5): .next
    case (0x0c, 0xb6): .previous
    case (0x07, 0x7f), (0x0c, 0xe2): .mute
    case (0x07, 0x80), (0x0c, 0xe9): .volumeUp
    case (0x07, 0x81), (0x0c, 0xea): .volumeDown
    default: nil
    }
  }
}
