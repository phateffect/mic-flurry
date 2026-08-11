#!/usr/bin/env swift

import AudioToolbox
import CoreAudio
import Foundation

private let deviceUID = "MicFlurry_UID"
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

private func findMicFlurry() throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    try check(
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size),
        "list audio devices"
    )

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var devices = Array(repeating: AudioDeviceID(0), count: count)
    try check(
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ),
        "read audio device list"
    )

    for device in devices {
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let uid: CFString = try propertyData(
            objectID: device,
            address: &uidAddress,
            initialValue: "" as CFString
        )
        if uid as String == deviceUID {
            return device
        }
    }

    throw NSError(
        domain: "MicFlurryASRVerification",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "MicFlurry is not loaded; install it and restart CoreAudio"]
    )
}

private func inputChannelCount(_ device: AudioDeviceID) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "size input layout")

    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { storage.deallocate() }
    try check(
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage),
        "read input layout"
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

private func nominalSampleRate(_ device: AudioDeviceID) throws -> Double {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    return try propertyData(objectID: device, address: &address, initialValue: Float64(0))
}

private func setNominalSampleRate(_ rate: Double, on device: AudioDeviceID) throws {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var mutableRate = rate
    try check(
        AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &mutableRate
        ),
        "set nominal sample rate to \(Int(rate)) Hz"
    )

    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        if try nominalSampleRate(device) == rate { return }
        Thread.sleep(forTimeInterval: 0.05)
    }
    throw NSError(
        domain: "MicFlurryASRVerification",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "timed out changing nominal sample rate to \(Int(rate)) Hz"]
    )
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

private func makeHALUnit(for device: AudioDeviceID) throws -> AudioUnit {
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
        "select MicFlurry in AUHAL"
    )
    return unit
}

private func verifyProducerFormat(on device: AudioDeviceID) throws {
    let unit = try makeHALUnit(for: device)
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
    let unit = try makeHALUnit(for: device)
    defer { AudioComponentInstanceDispose(unit) }
    var enabled: UInt32 = 1
    var disabled: UInt32 = 0
    try check(
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enabled,
            UInt32(MemoryLayout<UInt32>.size)
        ),
        "enable AUHAL input"
    )
    try check(
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disabled,
            UInt32(MemoryLayout<UInt32>.size)
        ),
        "disable unused AUHAL output"
    )
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
    let device = try findMicFlurry()
    let channels = try inputChannelCount(device)
    guard channels == 1 else {
        throw NSError(
            domain: "MicFlurryASRVerification",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "expected one input channel, found \(channels)"]
        )
    }

    let rates = try availableSampleRates(device)
    for requiredRate in [8_000.0, 16_000.0, 44_100.0, 48_000.0] where !rates.contains(requiredRate) {
        throw NSError(
            domain: "MicFlurryASRVerification",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "missing required sample rate \(Int(requiredRate)) Hz"]
        )
    }

    let originalRate = try nominalSampleRate(device)
    if originalRate != asrSampleRate {
        try setNominalSampleRate(asrSampleRate, on: device)
    }
    defer {
        if originalRate != asrSampleRate {
            try? setNominalSampleRate(originalRate, on: device)
        }
    }

    try verifyProducerFormat(on: device)
    try verifyConsumerFormat(on: device)
    print("PASS: producer and consumer AUHAL units accept signed Int16 mono PCM at 16 kHz.")
    print("PASS: required device rates are available: 8000, 16000, 44100, 48000 Hz.")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
