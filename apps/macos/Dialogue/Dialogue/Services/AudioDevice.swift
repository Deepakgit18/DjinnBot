import CoreAudio
import Foundation

/// Lightweight model representing a Core Audio input device.
///
/// Used by `AudioInputStreamer` to enumerate and select input devices
/// without coupling to `AudioInputDeviceManager` or AVAudioEngine.
public struct AudioDevice: Identifiable, Hashable, Sendable {
    /// CoreAudio device ID.
    public let audioDeviceID: AudioDeviceID
    /// Human-readable name (e.g. "MacBook Pro Microphone").
    public let name: String
    /// CoreAudio UID string (stable across reboots).
    public let uid: String
    /// Number of input channels on this device.
    public let inputChannels: Int

    public var id: AudioDeviceID { audioDeviceID }
}
