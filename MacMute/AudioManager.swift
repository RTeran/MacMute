import CoreAudio
import Foundation

class AudioManager {
    static let shared = AudioManager()

    private init() {}

    func setSystemMicMute(_ muted: Bool) {
        let deviceID = getDefaultInputDevice()
        guard deviceID != kAudioObjectUnknown else {
            NSLog("MacMute: No default input device found")
            return
        }

        var mute: UInt32 = muted ? 1 : 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &mute
        )

        if status != noErr {
            NSLog("MacMute: Failed to set mute state: \(status)")
        } else {
            NSLog("MacMute: System mic \(muted ? "muted" : "unmuted")")
        }
    }

    func isSystemMicMuted() -> Bool {
        let deviceID = getDefaultInputDevice()
        guard deviceID != kAudioObjectUnknown else { return false }

        var mute: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &mute
        )

        if status != noErr {
            NSLog("MacMute: Failed to get mute state: \(status)")
            return false
        }

        return mute != 0
    }

    private func getDefaultInputDevice() -> AudioDeviceID {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        if status != noErr {
            NSLog("MacMute: Failed to get default input device: \(status)")
            return kAudioObjectUnknown
        }

        return deviceID
    }
}
