import CoreAudio
import Foundation
import TingleCore

// Regression for 2026-10-27: with `switchDefaultInput` on, a 0.5s squeeze
// switched the system default input to the ting's adapter and restored it
// on release. AVAudioEngine followed the restore onto the old default
// (silence) but never posted the configuration-change notification that
// would have rebuilt the engine, so tinker captured silence for the rest
// of the session. The fix re-reads the engine's real input device and
// rebuilds when it is not the pinned one; this is that decision.
func runAudioBindingTests() {
    let pinned = AudioDeviceID(166)
    let other = AudioDeviceID(145)

    expect(!AudioBackend.bindingLost(engineRunning: true, captureDevices: [pinned], pinnedDevice: pinned),
           "binding: running on the pinned device is healthy")
    expect(AudioBackend.bindingLost(engineRunning: true, captureDevices: [other], pinnedDevice: pinned),
           "binding: running on another device (the incident) is lost")
    expect(!AudioBackend.bindingLost(engineRunning: true, captureDevices: [pinned], pinnedDevice: pinned),
           "binding: AVFAudio's default aggregate wrapping the pinned device still hears the ting")
    expect(AudioBackend.bindingLost(engineRunning: true, captureDevices: [], pinnedDevice: pinned),
           "binding: an aggregate with no live sub-device is lost")
    expect(AudioBackend.bindingLost(engineRunning: false, captureDevices: [pinned], pinnedDevice: pinned),
           "binding: a stopped engine is lost even if still pointed at the pinned device")
    expect(AudioBackend.bindingLost(engineRunning: true, captureDevices: nil, pinnedDevice: pinned),
           "binding: an unreadable (wedged) engine is lost")
    expect(!AudioBackend.bindingLost(engineRunning: true, captureDevices: [other], pinnedDevice: nil),
           "binding: a vanished pinned device is the coordinator's rescan, not a rebind")
    expect(!AudioBackend.bindingLost(engineRunning: false, captureDevices: nil, pinnedDevice: nil),
           "binding: nothing to do with no pinned device at all")

    // recheck on a backend that never started must be a silent no-op
    // (no engine to probe, nothing to rebuild) and must not block.
    let backend = AudioBackend(deviceUID: "tingle-test-nonexistent-device", frequencies: [17_500])
    let start = Date()
    backend.recheckDeviceBinding()
    expect(Date().timeIntervalSince(start) < 0.2, "binding: recheck returns immediately")
    let settled = DispatchSemaphore(value: 0)
    AudioEngineOps.queue.async { settled.signal() }
    expect(settled.wait(timeout: .now() + 2) == .success, "binding: recheck on an idle backend leaves the engine queue free")
    expect(!backend.isRunning, "binding: recheck never starts a backend that was not started")
    expect(backend.boundInputDeviceUID() == nil, "binding: no bound device without an engine")
    // Regression for 2026-10-28: the adapter was unplugged at 11:00, the
    // coordinator stopped the backend and at once created a replacement
    // that could not pin the absent device. That failed object stayed in
    // the slot, "if audio == nil" never fired again, and the adapter's
    // return at 17:35 went unnoticed — tinker was deaf until relaunch.
    typealias Pinned = PinnedInputPolicy
    expectEqual(Pinned.action(hasBackend: false, backendFailed: false, deviceExists: true), .start,
                "pinned: no backend and the device is present -> start")
    expectEqual(Pinned.action(hasBackend: true, backendFailed: false, deviceExists: true), .keep,
                "pinned: a healthy (or still starting) backend is left alone")
    expectEqual(Pinned.action(hasBackend: true, backendFailed: true, deviceExists: true), .restart,
                "pinned: a failed backend with the device present is replaced (the incident)")
    expectEqual(Pinned.action(hasBackend: false, backendFailed: false, deviceExists: false), .waitForDevice,
                "pinned: no device -> do not manufacture a backend that cannot pin")
    expectEqual(Pinned.action(hasBackend: true, backendFailed: true, deviceExists: false), .waitForDevice,
                "pinned: a failed backend is not retried until the device is back")
    expectEqual(Pinned.action(hasBackend: true, backendFailed: false, deviceExists: false), .waitForDevice,
                "pinned: device gone from under a live backend -> stop and wait")

    let fresh = AudioBackend(deviceUID: "no-such-device", frequencies: [18000])
    expect(!fresh.startFailed, "backend: a never-started backend has not failed")
    expect(!fresh.isRunning, "backend: a never-started backend is not running")

}
