import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Enumerates audio input devices on macOS and provides helpers to set
/// the input device on an `AVAudioEngine`.
///
/// Uses CoreAudio `AudioObjectGetPropertyData` to list devices and inspect
/// their input channel counts. Provides `setInputDevice(_:on:)` to change
/// which microphone an `AVAudioEngine` captures from.
enum AudioInputDeviceManager {

    // MARK: - Device Model

    struct InputDevice: Identifiable, Hashable {
        /// CoreAudio device ID.
        let audioDeviceID: AudioDeviceID
        /// Human-readable name (e.g. "MacBook Pro Microphone").
        let name: String
        /// CoreAudio UID string (stable across reboots).
        let uid: String
        /// Number of input channels.
        let inputChannels: Int

        var id: AudioDeviceID { audioDeviceID }
    }

    // MARK: - Enumerate

    /// Returns all audio devices that have at least one input channel.
    static func availableInputDevices() -> [InputDevice] {
        let deviceIDs = allDeviceIDs()
        var devices: [InputDevice] = []

        for deviceID in deviceIDs {
            let inputCount = channelCount(for: deviceID, scope: kAudioObjectPropertyScopeInput)
            guard inputCount > 0 else { continue }

            let name = deviceName(for: deviceID) ?? "Unknown Device"
            let uid = deviceUID(for: deviceID) ?? "\(deviceID)"
            devices.append(InputDevice(
                audioDeviceID: deviceID,
                name: name,
                uid: uid,
                inputChannels: inputCount
            ))
        }

        return devices
    }

    /// Returns the system default input device, if any.
    static func defaultInputDevice() -> InputDevice? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }

        let inputCount = channelCount(for: deviceID, scope: kAudioObjectPropertyScopeInput)
        guard inputCount > 0 else { return nil }

        let name = deviceName(for: deviceID) ?? "Default Input"
        let uid = deviceUID(for: deviceID) ?? "\(deviceID)"
        return InputDevice(
            audioDeviceID: deviceID,
            name: name,
            uid: uid,
            inputChannels: inputCount
        )
    }

    // MARK: - Set System Default Input Device

    /// Change the system-wide default input device via CoreAudio.
    ///
    /// This is equivalent to the user switching the input device in
    /// System Settings > Sound > Input. Any `AVAudioEngine` using the
    /// default device will receive a configuration change notification
    /// and can restart to pick up the new device.
    ///
    /// - Returns: `true` if the system default was changed successfully.
    @discardableResult
    static func setSystemDefaultInputDevice(_ device: InputDevice) -> Bool {
        var deviceID = device.audioDeviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )

        if status != noErr {
            Logger(subsystem: "bot.djinn.app.dialog", category: "AudioInputDeviceManager")
                .error("Failed to set system default input device to \(device.name) (ID \(device.audioDeviceID)): OSStatus \(status)")
            return false
        }

        Logger(subsystem: "bot.djinn.app.dialog", category: "AudioInputDeviceManager")
            .info("System default input device set to \(device.name) (ID \(device.audioDeviceID))")
        return true
    }

    // MARK: - Set Device on AVAudioEngine

    /// Set the input device for an `AVAudioEngine` by writing
    /// `kAudioOutputUnitProperty_CurrentDevice` on the input node's audio unit.
    ///
    /// Must be called **before** `engine.start()`.
    @discardableResult
    static func setInputDevice(_ device: InputDevice, on engine: AVAudioEngine) -> Bool {
        guard let audioUnit = engine.inputNode.audioUnit else {
            Logger(subsystem: "bot.djinn.app.dialog", category: "AudioInputDeviceManager")
                .error("No audio unit on inputNode")
            return false
        }

        var deviceID = device.audioDeviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status != noErr {
            Logger(subsystem: "bot.djinn.app.dialog", category: "AudioInputDeviceManager")
                .error("Failed to set input device \(device.name) (ID \(device.audioDeviceID)): OSStatus \(status)")
            return false
        }

        return true
    }

    // MARK: - Private Helpers

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        )
        guard status == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceIDs
        )
        guard status == noErr else { return [] }
        return deviceIDs
    }

    private static func channelCount(for deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return 0 }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferListPointer.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPointer)
        guard status == noErr else { return 0 }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        var totalChannels = 0
        for buffer in bufferList {
            totalChannels += Int(buffer.mNumberChannels)
        }
        return totalChannels
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr else { return nil }
        return name as String
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr else { return nil }
        return uid as String
    }
}
