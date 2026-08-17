@preconcurrency import CoreBluetooth
import Foundation
import MicFlurryATVV
import MicFlurryDomain

public enum BluetoothAdapterError: Error, Equatable, Sendable {
  case unavailable(CBManagerState)
  case peripheralNotConnected(DeviceID)
  case unsupportedDevice(DeviceID)
  case missingCharacteristic(String)
  case coreBluetooth(String)
  case operationInProgress
}

public enum BluetoothEvent: Equatable, Sendable {
  case control(device: DeviceID, bytes: [UInt8])
  case audio(device: DeviceID, bytes: [UInt8])
  case disconnected(DeviceID)
}

@MainActor
public protocol BluetoothTransport: AnyObject {
  var events: AsyncStream<BluetoothEvent> { get }
  func connectedATVVDevices() async throws -> [Device]
  func attachedDeviceIsConnected() -> Bool
  func attach(to deviceID: DeviceID) async throws -> DeviceInfo
  func writeCommand(_ bytes: [UInt8]) throws
  func release() async throws
}

@MainActor
public final class BluetoothAdapter: NSObject {
  public let events: AsyncStream<BluetoothEvent>

  private let eventContinuation: AsyncStream<BluetoothEvent>.Continuation
  private var central: CBCentralManager!
  private var stateWaiters: [CheckedContinuation<Void, any Error>] = []
  private var peripherals: [UUID: CBPeripheral] = [:]
  private var activePeripheral: CBPeripheral?
  private var activeConnectionOwned = false
  private var transmitCharacteristic: CBCharacteristic?
  private var attachment: Attachment?

  public override init() {
    let stream = AsyncStream.makeStream(
      of: BluetoothEvent.self,
      bufferingPolicy: .bufferingNewest(128)
    )
    events = stream.stream
    eventContinuation = stream.continuation
    super.init()
    central = CBCentralManager(
      delegate: self,
      queue: .main,
      options: [CBCentralManagerOptionShowPowerAlertKey: false]
    )
  }

  deinit {
    eventContinuation.finish()
  }

  public func connectedATVVDevices() async throws -> [Device] {
    try await waitUntilReady()
    let connected = central.retrieveConnectedPeripherals(withServices: [UUIDs.service])
    peripherals = Dictionary(uniqueKeysWithValues: connected.map { ($0.identifier, $0) })
    let identities = HIDIdentityProvider.identities()
    return connected.map { peripheral in
      let identity = identities[peripheral.identifier]
      let supported = HIDIdentityProvider.isSupportedXiaomiRemote(identity)
      return Device(
        id: DeviceID(rawValue: peripheral.identifier.uuidString),
        name: peripheral.name ?? identity?.product ?? "Connected ATVV remote",
        known: false,
        connected: true,
        supportsATVV: true,
        support: supported ? .supported(model: "RC001/RC003") : .unsupported
      )
    }
  }

  public func attachedDeviceIsConnected() -> Bool {
    guard let activePeripheral, activePeripheral.state == .connected else { return false }
    return central.retrieveConnectedPeripherals(withServices: [UUIDs.service]).contains {
      $0.identifier == activePeripheral.identifier
    }
  }

  public func attach(to deviceID: DeviceID) async throws -> DeviceInfo {
    guard attachment == nil else { throw BluetoothAdapterError.operationInProgress }
    guard let identifier = UUID(uuidString: deviceID.rawValue),
      let peripheral = peripherals[identifier]
    else { throw BluetoothAdapterError.peripheralNotConnected(deviceID) }
    guard
      HIDIdentityProvider.isSupportedXiaomiRemote(HIDIdentityProvider.identities()[identifier])
    else {
      throw BluetoothAdapterError.unsupportedDevice(deviceID)
    }

    try await release()
    peripheral.delegate = self
    return try await withCheckedThrowingContinuation { continuation in
      let operation = Attachment(
        deviceID: deviceID,
        peripheral: peripheral,
        connectionOwned: peripheral.state != .connected,
        continuation: continuation
      )
      attachment = operation
      operation.timeoutTask = Task { [weak self, weak operation] in
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled, let self, self.attachment === operation else { return }
        self.failAttachment(BluetoothAdapterError.coreBluetooth("ATVV attachment timed out"))
      }
      if operation.connectionOwned {
        central.connect(peripheral)
      } else {
        peripheral.discoverServices([UUIDs.service, UUIDs.deviceInformation])
      }
    }
  }

  public func writeCommand(_ bytes: [UInt8]) throws {
    guard let peripheral = activePeripheral, let transmitCharacteristic else {
      throw BluetoothAdapterError.missingCharacteristic("ATVV transmit")
    }
    peripheral.writeValue(Data(bytes), for: transmitCharacteristic, type: .withoutResponse)
  }

  public func release() async throws {
    if let peripheral = activePeripheral {
      let connectionOwned = activeConnectionOwned
      for service in peripheral.services ?? [] {
        for characteristic in service.characteristics ?? []
        where characteristic.uuid == UUIDs.audio || characteristic.uuid == UUIDs.control {
          if characteristic.isNotifying {
            peripheral.setNotifyValue(false, for: characteristic)
          }
        }
      }
      peripheral.delegate = nil
      activePeripheral = nil
      transmitCharacteristic = nil
      activeConnectionOwned = false
      if connectionOwned { central.cancelPeripheralConnection(peripheral) }
    }
  }

  private func waitUntilReady() async throws {
    if central.state == .poweredOn { return }
    if ![.unknown, .resetting].contains(central.state) {
      throw BluetoothAdapterError.unavailable(central.state)
    }
    try await withCheckedThrowingContinuation { continuation in
      stateWaiters.append(continuation)
    }
  }

  private func failAttachment(_ error: any Error) {
    guard let attachment else { return }
    self.attachment = nil
    attachment.timeoutTask?.cancel()
    for characteristic in [attachment.audio, attachment.control].compactMap({ $0 })
    where characteristic.isNotifying {
      attachment.peripheral.setNotifyValue(false, for: characteristic)
    }
    attachment.peripheral.delegate = nil
    if attachment.connectionOwned {
      central.cancelPeripheralConnection(attachment.peripheral)
    }
    attachment.continuation.resume(throwing: error)
  }

  private func finishAttachmentIfReady() {
    guard let attachment,
      attachment.pendingCharacteristicDiscoveries == 0,
      attachment.pendingNotifications == 0,
      attachment.pendingReads.isEmpty
    else { return }
    guard let transmit = attachment.transmit,
      attachment.audio != nil,
      attachment.control != nil
    else {
      failAttachment(BluetoothAdapterError.missingCharacteristic("ATVV service"))
      return
    }

    let peripheral = attachment.peripheral
    peripheral.writeValue(Data(ATVV.getCapabilities), for: transmit, type: .withoutResponse)
    activePeripheral = peripheral
    activeConnectionOwned = attachment.connectionOwned
    transmitCharacteristic = transmit
    self.attachment = nil
    attachment.timeoutTask?.cancel()
    attachment.continuation.resume(returning: attachment.deviceInfo)
  }
}

extension BluetoothAdapter: BluetoothTransport {}

extension BluetoothAdapter: CBCentralManagerDelegate {
  public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
    Task { @MainActor in
      let waiters = stateWaiters
      stateWaiters.removeAll()
      if central.state == .poweredOn {
        for waiter in waiters {
          waiter.resume()
        }
      } else if ![.unknown, .resetting].contains(central.state) {
        for waiter in waiters {
          waiter.resume(throwing: BluetoothAdapterError.unavailable(central.state))
        }
      } else {
        stateWaiters.append(contentsOf: waiters)
      }
    }
  }

  public nonisolated func centralManager(
    _ central: CBCentralManager,
    didConnect peripheral: CBPeripheral
  ) {
    Task { @MainActor in
      guard let attachment, attachment.peripheral === peripheral else { return }
      peripheral.discoverServices([UUIDs.service, UUIDs.deviceInformation])
    }
  }

  public nonisolated func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: (any Error)?
  ) {
    Task { @MainActor in
      guard let attachment, attachment.peripheral === peripheral else { return }
      let message =
        error?.localizedDescription ?? "CoreBluetooth could not attach to the peripheral"
      failAttachment(BluetoothAdapterError.coreBluetooth(message))
    }
  }

  public nonisolated func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    timestamp: CFAbsoluteTime,
    isReconnecting: Bool,
    error: (any Error)?
  ) {
    Task { @MainActor in
      if let attachment, attachment.peripheral === peripheral {
        let message = error?.localizedDescription ?? "peripheral disconnected during attachment"
        failAttachment(BluetoothAdapterError.coreBluetooth(message))
        return
      }
      guard activePeripheral?.identifier == peripheral.identifier else { return }
      let deviceID = DeviceID(rawValue: peripheral.identifier.uuidString)
      activePeripheral = nil
      transmitCharacteristic = nil
      activeConnectionOwned = false
      eventContinuation.yield(.disconnected(deviceID))
    }
  }
}

extension BluetoothAdapter: CBPeripheralDelegate {
  public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?)
  {
    Task { @MainActor in
      guard let attachment, attachment.peripheral === peripheral else { return }
      if let error {
        failAttachment(BluetoothAdapterError.coreBluetooth(error.localizedDescription))
        return
      }
      let services = peripheral.services ?? []
      attachment.pendingCharacteristicDiscoveries = services.count
      if services.isEmpty {
        failAttachment(BluetoothAdapterError.missingCharacteristic("ATVV service"))
        return
      }
      for service in services {
        if service.uuid == UUIDs.service {
          peripheral.discoverCharacteristics(
            [UUIDs.transmit, UUIDs.audio, UUIDs.control],
            for: service
          )
        } else if service.uuid == UUIDs.deviceInformation {
          peripheral.discoverCharacteristics(UUIDs.deviceInformationCharacteristics, for: service)
        } else {
          attachment.pendingCharacteristicDiscoveries -= 1
        }
      }
      finishAttachmentIfReady()
    }
  }

  public nonisolated func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    Task { @MainActor in
      guard let attachment, attachment.peripheral === peripheral else { return }
      if let error {
        failAttachment(BluetoothAdapterError.coreBluetooth(error.localizedDescription))
        return
      }
      for characteristic in service.characteristics ?? [] {
        switch characteristic.uuid {
        case UUIDs.transmit:
          attachment.transmit = characteristic
        case UUIDs.audio:
          attachment.audio = characteristic
          attachment.pendingNotifications += 1
          peripheral.setNotifyValue(true, for: characteristic)
        case UUIDs.control:
          attachment.control = characteristic
          attachment.pendingNotifications += 1
          peripheral.setNotifyValue(true, for: characteristic)
        default:
          if UUIDs.deviceInformationCharacteristics.contains(characteristic.uuid) {
            attachment.pendingReads.insert(characteristic.uuid)
            peripheral.readValue(for: characteristic)
          }
        }
      }
      attachment.pendingCharacteristicDiscoveries -= 1
      finishAttachmentIfReady()
    }
  }

  public nonisolated func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    Task { @MainActor in
      guard let attachment, attachment.peripheral === peripheral else { return }
      if let error {
        failAttachment(BluetoothAdapterError.coreBluetooth(error.localizedDescription))
        return
      }
      attachment.pendingNotifications -= 1
      finishAttachmentIfReady()
    }
  }

  public nonisolated func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    Task { @MainActor in
      if let attachment, attachment.peripheral === peripheral,
        attachment.pendingReads.remove(characteristic.uuid) != nil
      {
        if error == nil, let value = characteristic.value {
          attachment.applyDeviceInformation(value, characteristic: characteristic.uuid)
        }
        finishAttachmentIfReady()
        return
      }
      guard let activePeripheral, activePeripheral === peripheral,
        error == nil,
        let value = characteristic.value
      else { return }
      let deviceID = DeviceID(rawValue: peripheral.identifier.uuidString)
      if characteristic.uuid == UUIDs.audio {
        eventContinuation.yield(.audio(device: deviceID, bytes: [UInt8](value)))
      } else if characteristic.uuid == UUIDs.control {
        eventContinuation.yield(.control(device: deviceID, bytes: [UInt8](value)))
      }
    }
  }
}

@MainActor
private final class Attachment {
  let deviceID: DeviceID
  let peripheral: CBPeripheral
  let connectionOwned: Bool
  let continuation: CheckedContinuation<DeviceInfo, any Error>
  var transmit: CBCharacteristic?
  var audio: CBCharacteristic?
  var control: CBCharacteristic?
  var pendingCharacteristicDiscoveries = 0
  var pendingNotifications = 0
  var pendingReads: Set<CBUUID> = []
  var deviceInfo = DeviceInfo()
  var timeoutTask: Task<Void, Never>?

  init(
    deviceID: DeviceID,
    peripheral: CBPeripheral,
    connectionOwned: Bool,
    continuation: CheckedContinuation<DeviceInfo, any Error>
  ) {
    self.deviceID = deviceID
    self.peripheral = peripheral
    self.connectionOwned = connectionOwned
    self.continuation = continuation
    deviceInfo.attMTU = UInt16(
      clamping: peripheral.maximumWriteValueLength(for: .withoutResponse) + 3
    )
    if let identity = HIDIdentityProvider.identities()[peripheral.identifier] {
      deviceInfo.hidManufacturer = identity.manufacturer
      deviceInfo.hidProduct = identity.product
      deviceInfo.hidVendorID = identity.vendorID
      deviceInfo.hidProductID = identity.productID
      deviceInfo.hidTransport = identity.transport
      deviceInfo.hidSerialNumber = identity.serialNumber
      deviceInfo.hidVersionNumber = identity.versionNumber
      deviceInfo.physicalDeviceID = identity.physicalDeviceID
    }
  }

  func applyDeviceInformation(_ data: Data, characteristic: CBUUID) {
    let value = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: CharacterSet.controlCharacters.union(.whitespacesAndNewlines))
    guard !value.isEmpty else { return }
    switch characteristic {
    case UUIDs.manufacturerName: deviceInfo.manufacturerName = value
    case UUIDs.modelNumber: deviceInfo.modelNumber = value
    case UUIDs.serialNumber: deviceInfo.serialNumber = value
    case UUIDs.hardwareRevision: deviceInfo.hardwareRevision = value
    case UUIDs.firmwareRevision: deviceInfo.firmwareRevision = value
    case UUIDs.softwareRevision: deviceInfo.softwareRevision = value
    default: break
    }
  }
}

private enum UUIDs {
  static let service = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
  static let transmit = CBUUID(string: "AB5E0002-5A21-4F05-BC7D-AF01F617B664")
  static let audio = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
  static let control = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")
  static let deviceInformation = CBUUID(string: "180A")
  static let modelNumber = CBUUID(string: "2A24")
  static let serialNumber = CBUUID(string: "2A25")
  static let firmwareRevision = CBUUID(string: "2A26")
  static let hardwareRevision = CBUUID(string: "2A27")
  static let softwareRevision = CBUUID(string: "2A28")
  static let manufacturerName = CBUUID(string: "2A29")
  static let deviceInformationCharacteristics: [CBUUID] = [
    modelNumber,
    serialNumber,
    firmwareRevision,
    hardwareRevision,
    softwareRevision,
    manufacturerName,
  ]
}
