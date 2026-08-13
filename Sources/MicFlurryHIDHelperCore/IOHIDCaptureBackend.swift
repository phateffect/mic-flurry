import Foundation
import IOKit.hid
import MicFlurryHIDProtocol

@MainActor
public final class IOHIDCaptureBackend: HIDCaptureBackend {
  public typealias EventSink = @MainActor (HIDCaptureEvent) -> Void
  public typealias UnexpectedStopSink = @MainActor (String) -> Void

  private let eventSink: EventSink
  private let capture = AtomicHIDCapture()
  private var manager: IOHIDManager?
  private var emitter: HIDEventEmitter?
  public var unexpectedStopSink: UnexpectedStopSink?

  public init(eventSink: @escaping EventSink) {
    self.eventSink = eventSink
  }

  public func start(profile: HIDDeviceProfile, physicalDeviceID: String?) throws {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, nil)
    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
      throw IOHIDCaptureBackendError.enumerationFailed
    }
    let candidates = devices.map { device in
      (device, Self.descriptor(for: device, fallbackReportBytes: profile.maximumReportBytes))
    }
    let selected = try HIDInterfaceSelection.select(
      candidates.map(\.1),
      profile: profile,
      physicalDeviceID: physicalDeviceID
    )
    let selectedIdentifiers = Set(selected.map(\.identifier))
    guard let selectedPhysicalID = selected.first?.physicalDeviceID else {
      throw HIDCaptureError.noMatchingDevice
    }
    let emitter = HIDEventEmitter(physicalDeviceID: selectedPhysicalID, sink: eventSink)
    let interfaces: [any HIDCaptureInterface] =
      candidates
      .filter { selectedIdentifiers.contains($0.1.identifier) }
      .sorted { $0.1.identifier < $1.1.identifier }
      .map {
        IOHIDCaptureInterface(
          device: $0.0,
          descriptor: $0.1,
          emitter: emitter,
          removalSink: { [weak self] identifier in
            self?.interfaceWasRemoved(identifier)
          }
        )
      }
    do {
      try capture.start(interfaces: interfaces)
      self.manager = manager
      self.emitter = emitter
    } catch {
      self.manager = nil
      self.emitter = nil
      throw error
    }
  }

  public func stop() {
    capture.stop()
    emitter = nil
    manager = nil
  }

  private func interfaceWasRemoved(_ identifier: String) {
    guard manager != nil else { return }
    stop()
    unexpectedStopSink?("device_removed:\(identifier)")
  }

  private static func descriptor(
    for device: IOHIDDevice,
    fallbackReportBytes: Int
  ) -> HIDInterfaceDescriptor {
    var registryID: UInt64 = 0
    let service = IOHIDDeviceGetService(device)
    IORegistryEntryGetRegistryEntryID(service, &registryID)
    return HIDInterfaceDescriptor(
      identifier: String(format: "%016llx", registryID),
      physicalDeviceID: stringProperty(device, key: "PhysicalDeviceUniqueID") ?? "",
      manufacturer: stringProperty(device, key: "Manufacturer"),
      vendorID: numberProperty(device, key: "VendorID").flatMap(UInt32.init(exactly:)),
      productID: numberProperty(device, key: "ProductID").flatMap(UInt32.init(exactly:)),
      product: stringProperty(device, key: "Product"),
      transport: stringProperty(device, key: "Transport"),
      maximumInputReportBytes: numberProperty(device, key: "MaxInputReportSize")
        .flatMap(Int.init(exactly:)) ?? fallbackReportBytes
    )
  }

  private static func stringProperty(_ device: IOHIDDevice, key: String) -> String? {
    IOHIDDeviceGetProperty(device, key as CFString) as? String
  }

  private static func numberProperty(_ device: IOHIDDevice, key: String) -> Int64? {
    (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.int64Value
  }
}

public enum IOHIDCaptureBackendError: Error, Equatable, Sendable {
  case enumerationFailed
  case seizeFailed(interface: String, result: IOReturn)
}

@MainActor
private final class HIDEventEmitter {
  let physicalDeviceID: String
  let startedAt = DispatchTime.now().uptimeNanoseconds
  let sink: IOHIDCaptureBackend.EventSink
  var sequence: UInt64 = 0

  init(physicalDeviceID: String, sink: @escaping IOHIDCaptureBackend.EventSink) {
    self.physicalDeviceID = physicalDeviceID
    self.sink = sink
  }

  func emit(interfaceIndex: UInt16, kind: HIDEventKind) {
    sequence &+= 1
    sink(
      HIDCaptureEvent(
        sequence: sequence,
        monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt,
        physicalDeviceID: physicalDeviceID,
        interfaceIndex: interfaceIndex,
        kind: kind
      )
    )
  }
}

@MainActor
private final class IOHIDCaptureInterface: HIDCaptureInterface {
  let descriptor: HIDInterfaceDescriptor

  private let device: IOHIDDevice
  private let context: IOHIDCallbackContext
  private var reportBuffer: UnsafeMutablePointer<UInt8>?
  private var callbacksInstalled = false
  private var opened = false

  init(
    device: IOHIDDevice,
    descriptor: HIDInterfaceDescriptor,
    emitter: HIDEventEmitter,
    removalSink: @escaping @MainActor (String) -> Void
  ) {
    self.device = device
    self.descriptor = descriptor
    context = IOHIDCallbackContext(
      interfaceIdentifier: descriptor.identifier,
      emitter: emitter,
      removalSink: removalSink
    )
  }

  func openSeized() throws {
    let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    guard result == kIOReturnSuccess else {
      throw IOHIDCaptureBackendError.seizeFailed(
        interface: descriptor.identifier,
        result: result
      )
    }
    opened = true
  }

  func installCallbacks(interfaceIndex: UInt16) throws {
    context.interfaceIndex = interfaceIndex
    let buffer = UnsafeMutablePointer<UInt8>.allocate(
      capacity: descriptor.maximumInputReportBytes
    )
    buffer.initialize(repeating: 0, count: descriptor.maximumInputReportBytes)
    reportBuffer = buffer
    let contextPointer = Unmanaged.passUnretained(context).toOpaque()
    IOHIDDeviceRegisterRemovalCallback(device, hidRemovalCallback, contextPointer)
    IOHIDDeviceRegisterInputValueCallback(device, hidValueCallback, contextPointer)
    IOHIDDeviceRegisterInputReportCallback(
      device,
      buffer,
      descriptor.maximumInputReportBytes,
      hidReportCallback,
      contextPointer
    )
    IOHIDDeviceScheduleWithRunLoop(
      device,
      CFRunLoopGetMain(),
      CFRunLoopMode.defaultMode.rawValue
    )
    callbacksInstalled = true
  }

  func uninstallCallbacks() {
    guard callbacksInstalled else { return }
    callbacksInstalled = false
    IOHIDDeviceUnscheduleFromRunLoop(
      device,
      CFRunLoopGetMain(),
      CFRunLoopMode.defaultMode.rawValue
    )
    IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
    IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
    if let reportBuffer {
      IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 0, nil, nil)
    }
    reportBuffer?.deinitialize(count: descriptor.maximumInputReportBytes)
    reportBuffer?.deallocate()
    reportBuffer = nil
  }

  func close() {
    guard opened else { return }
    opened = false
    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
  }
}

@MainActor
private final class IOHIDCallbackContext {
  let interfaceIdentifier: String
  let emitter: HIDEventEmitter
  let removalSink: @MainActor (String) -> Void
  var interfaceIndex: UInt16 = 0

  init(
    interfaceIdentifier: String,
    emitter: HIDEventEmitter,
    removalSink: @escaping @MainActor (String) -> Void
  ) {
    self.interfaceIdentifier = interfaceIdentifier
    self.emitter = emitter
    self.removalSink = removalSink
  }
}

private let hidRemovalCallback: IOHIDCallback = { context, _, _ in
  guard let context else { return }
  let callback = Unmanaged<IOHIDCallbackContext>.fromOpaque(context).takeUnretainedValue()
  let identifier = callback.interfaceIdentifier
  Task { @MainActor in
    callback.removalSink(identifier)
  }
}

private let hidReportCallback: IOHIDReportCallback = {
  context,
  result,
  _,
  reportType,
  reportID,
  report,
  reportLength in
  guard result == kIOReturnSuccess,
    let context,
    reportLength > 0
  else { return }
  let callback = Unmanaged<IOHIDCallbackContext>.fromOpaque(context).takeUnretainedValue()
  let bytes = Data(bytes: report, count: reportLength)
  Task { @MainActor in
    callback.emitter.emit(
      interfaceIndex: callback.interfaceIndex,
      kind: .rawReport(
        reportType: UInt32(reportType.rawValue),
        reportID: reportID,
        bytes: bytes
      )
    )
  }
}

private let hidValueCallback: IOHIDValueCallback = { context, result, _, value in
  guard result == kIOReturnSuccess, let context else { return }
  let element = IOHIDValueGetElement(value)
  let usagePage = IOHIDElementGetUsagePage(element)
  let usage = IOHIDElementGetUsage(element)
  let integer = Int64(IOHIDValueGetIntegerValue(value))
  let callback = Unmanaged<IOHIDCallbackContext>.fromOpaque(context).takeUnretainedValue()
  Task { @MainActor in
    callback.emitter.emit(
      interfaceIndex: callback.interfaceIndex,
      kind: .value(usagePage: usagePage, usage: usage, value: integer)
    )
  }
}
