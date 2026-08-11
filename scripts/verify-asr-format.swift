#!/usr/bin/env swift

import AudioToolbox
import CoreAudio
import Foundation

private let inputDeviceUID = "MicFlurry_UID"
private let injectionDeviceUID = "MicFlurry_2_UID"
private let asrSampleRate = 16_000.0

private func describe(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return "'\(String(bytes: bytes, encoding: .ascii)!)' (\(status))"
    }
    return String(status)
}

private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw NSError(
            domain: "MicFlurryASRVerification",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(describe(status))"]
        )
    }
}

private func propertyData<T>(
    objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    initialValue: T
) throws -> T {
    var value = initialValue
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutableBytes(of: &value) { storage in
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage.baseAddress!)
    }
    try check(status, "read CoreAudio property")
    return value
}

private func findDevice(uid: String) throws -> AudioDeviceID {
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
    try check(status, "resolve CoreAudio device UID \(uid)")
    guard device != kAudioObjectUnknown else {
        throw NSError(
            domain: "MicFlurryASRVerification",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "CoreAudio device \(uid) is not loaded; install MicFlurry and restart CoreAudio"
            ]
        )
    }
    return device
}

private func deviceName(_ device: AudioDeviceID) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let name: CFString = try propertyData(
        objectID: device,
        address: &address,
        initialValue: "" as CFString
    )
    return name as String
}

private func isHidden(_ device: AudioDeviceID) throws -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyIsHidden,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let value: UInt32 = try propertyData(objectID: device, address: &address, initialValue: 0)
    return value != 0
}

private func channelCount(
    _ device: AudioDeviceID,
    scope: AudioObjectPropertyScope,
    label: String
) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "size \(label) layout")

    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { storage.deallocate() }
    try check(
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage),
        "read \(label) layout"
    )

    let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
    return buffers.reduce(0) { $0 + $1.mNumberChannels }
}

private func availableSampleRates(_ device: AudioDeviceID) throws -> [Double] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "size sample rates")
    let count = Int(size) / MemoryLayout<AudioValueRange>.size
    var ranges = Array(repeating: AudioValueRange(), count: count)
    try check(
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ranges),
        "read sample rates"
    )
    return ranges.filter { $0.mMinimum == $0.mMaximum }.map(\.mMinimum)
}

private func signedInt16MonoASBD() -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: asrSampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2,
        mFramesPerPacket: 1,
        mBytesPerFrame: 2,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 16,
        mReserved: 0
    )
}

private func makeHALUnit(
    for device: AudioDeviceID,
    inputEnabled: Bool,
    label: String
) throws -> AudioUnit {
    var description = AudioComponentDescription(
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    )
    guard let component = AudioComponentFindNext(nil, &description) else {
        throw NSError(
            domain: "MicFlurryASRVerification",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "AUHAL component is unavailable"]
        )
    }
    var unit: AudioUnit?
    try check(AudioComponentInstanceNew(component, &unit), "create AUHAL instance")
    guard let unit else { fatalError("AudioComponentInstanceNew returned no instance") }

    var inputState: UInt32 = inputEnabled ? 1 : 0
    var outputState: UInt32 = inputEnabled ? 0 : 1
    try check(
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &inputState,
            UInt32(MemoryLayout<UInt32>.size)
        ),
        "configure \(label) AUHAL input state"
    )
    try check(
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &outputState,
            UInt32(MemoryLayout<UInt32>.size)
        ),
        "configure \(label) AUHAL output state"
    )

    var mutableDevice = device
    try check(
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDevice,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        ),
        "select \(label) in AUHAL"
    )
    return unit
}

private func verifyProducerFormat(on device: AudioDeviceID) throws {
    let unit = try makeHALUnit(
        for: device,
        inputEnabled: false,
        label: "MicFlurry Internal"
    )
    defer { AudioComponentInstanceDispose(unit) }
    var format = signedInt16MonoASBD()
    try check(
        AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ),
        "configure producer as signed Int16 mono 16 kHz"
    )
    try check(AudioUnitInitialize(unit), "initialize producer AUHAL")
    AudioUnitUninitialize(unit)
}

private func verifyConsumerFormat(on device: AudioDeviceID) throws {
    let unit = try makeHALUnit(
        for: device,
        inputEnabled: true,
        label: "MicFlurry"
    )
    defer { AudioComponentInstanceDispose(unit) }
    var format = signedInt16MonoASBD()
    try check(
        AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ),
        "configure consumer as signed Int16 mono 16 kHz"
    )
    try check(AudioUnitInitialize(unit), "initialize consumer AUHAL")
    AudioUnitUninitialize(unit)
}

do {
    let inputDevice = try findDevice(uid: inputDeviceUID)
    let injectionDevice = try findDevice(uid: injectionDeviceUID)

    guard try deviceName(inputDevice) == "MicFlurry", try !isHidden(inputDevice) else {
        throw NSError(
            domain: "MicFlurryASRVerification",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "MicFlurry input endpoint has the wrong name or visibility"]
        )
    }
    guard try deviceName(injectionDevice) == "MicFlurry Internal", try isHidden(injectionDevice) else {
        throw NSError(
            domain: "MicFlurryASRVerification",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "MicFlurry Internal has the wrong name or visibility"]
        )
    }

    let inputChannels = try channelCount(
        inputDevice, scope: kAudioDevicePropertyScopeInput, label: "MicFlurry input"
    )
    let visibleOutputChannels = try channelCount(
        inputDevice, scope: kAudioDevicePropertyScopeOutput, label: "MicFlurry output"
    )
    let internalInputChannels = try channelCount(
        injectionDevice, scope: kAudioDevicePropertyScopeInput, label: "MicFlurry Internal input"
    )
    let injectionChannels = try channelCount(
        injectionDevice, scope: kAudioDevicePropertyScopeOutput, label: "MicFlurry Internal output"
    )
    guard inputChannels == 1, visibleOutputChannels == 0,
        internalInputChannels == 0, injectionChannels == 1
    else {
        throw NSError(
            domain: "MicFlurryASRVerification",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "expected visible 1-in/0-out and internal 0-in/1-out topology"
            ]
        )
    }

    for device in [inputDevice, injectionDevice] {
        let rates = try availableSampleRates(device)
        for requiredRate in [8_000.0, 16_000.0, 44_100.0, 48_000.0]
        where !rates.contains(requiredRate) {
            throw NSError(
                domain: "MicFlurryASRVerification",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "missing required sample rate \(Int(requiredRate)) Hz"]
            )
        }
    }

    try verifyProducerFormat(on: injectionDevice)
    try verifyConsumerFormat(on: inputDevice)
    print("PASS: MicFlurry is visible input-only and MicFlurry Internal is hidden output-only.")
    print("PASS: producer and consumer AUHAL units accept signed Int16 mono PCM at 16 kHz.")
    print("PASS: both endpoints offer 8000, 16000, 44100, and 48000 Hz.")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
