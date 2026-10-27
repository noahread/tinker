import CoreAudio
import Foundation
import os

/// Optional (`[routing] switchDefaultInput`): make the ting's capture
/// device the system default input while the handle is held, so an
/// external dictation app records the ting's mic rather than the laptop's.
/// Restores the previous default on release and at quit.
final class DefaultInputSwitcher {
    private let log = Logger(subsystem: Log.subsystem, category: "inputswitch")
    private var saved: AudioDeviceID?

    static func currentDefault() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    @discardableResult
    static func setDefault(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &value) == noErr
    }

    /// Switch to the device with this UID (no-op if already the default).
    func engage(uid: String) {
        guard saved == nil, let target = AudioBackend.deviceID(forUID: uid),
              let current = Self.currentDefault(), current != target else { return }
        if Self.setDefault(target) {
            saved = current
            log.info("default input switched to \(uid, privacy: .public) for the squeeze")
        } else {
            log.error("failed to switch default input to \(uid, privacy: .public)")
        }
    }

    func restore() {
        guard let saved else { return }
        self.saved = nil
        if Self.setDefault(saved) {
            log.info("default input restored")
        } else {
            log.error("failed to restore default input device \(saved)")
        }
    }
}
