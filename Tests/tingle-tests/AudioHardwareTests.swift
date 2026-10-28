import AVFoundation
import CoreAudio
import Foundation
import TingleCore

// End-to-end AVAudioEngine lifecycle tests against REAL capture hardware —
// the deterministic repro for the 2026-07 freeze class that pure unit tests
// cannot reach. Runs the full production path: start on a pinned line-in,
// survive the spurious post-start configuration-change notification, force
// the unhealthy path (teardown + fresh rebuild, exactly what a device
// sleep/change triggers), and the WarmCapture attach/reuse lifecycle.
//
// Gated three ways so CI and hardware-less machines skip cleanly:
//   TINGLE_HW_TESTS=1 swift run tingle-tests      (stop the tingle app first
//   — two processes' engines on one device is not a supported state)
func runAudioHardwareTests() {
    guard ProcessInfo.processInfo.environment["TINGLE_HW_TESTS"] == "1" else {
        print("SKIP  audio hardware tests (TINGLE_HW_TESTS=1 to run, with the tingle app stopped)")
        return
    }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        print("SKIP  audio hardware tests (invoking terminal lacks microphone permission)")
        return
    }
    guard let device = firstLineInDevice() else {
        print("SKIP  audio hardware tests (no line-in capture device present)")
        return
    }
    print("audio hardware tests on \(device.name)")

    let backend = AudioBackend(deviceUID: device.uid,
                               frequencies: [17_500, 18_000, 18_500, 19_000])
    backend.start()
    expect(spin(5) { backend.isRunning }, "hw: backend starts on the line-in device")
    expect(backend.inputFormat != nil, "hw: input format known once running")

    // Engine start posts one spurious configuration-change notification;
    // the health probe must keep the engine (regression: rebuild storm).
    _ = spin(1.5) { false }
    expect(backend.isRunning, "hw: engine survives the spurious post-start notification")

    // Tap buffers actually reach the shared consumer (dictation's path).
    let lock = NSLock()
    var buffers = 0
    backend.bufferConsumer = { _ in lock.lock(); buffers += 1; lock.unlock() }
    expect(spin(3) { lock.withCount { buffers } >= 5 }, "hw: tap buffers flow to the shared consumer")

    // Incident-shaped recovery: force the handler down the unhealthy path.
    // This is teardown (bounded dispose of a LIVE engine) + fresh rebuild —
    // the same code a real device sleep/configuration change executes.
    backend._testHealthProbeOverride = { false }
    backend._testPostConfigurationChange()
    expect(spin(3) { !backend.isRunning }, "hw: forced configuration change tears the engine down")
    expect(spin(5) { backend.isRunning }, "hw: engine rebuilds fresh after the configuration change")
    lock.lock(); buffers = 0; lock.unlock()
    expect(spin(3) { lock.withCount { buffers } >= 5 }, "hw: buffers flow through the rebuilt engine")

    // tinker 2026-10-27: a squeeze-time default-input switch and restore
    // drags AVAudioEngine's input onto the restored default; the binding
    // recheck must bring it back to the pinned device even when AVFAudio
    // never posts the configuration-change notification.
    if let pinnedID = deviceID(forUID: device.uid), let previousDefault = defaultInputDevice(),
       previousDefault != pinnedID {
        expect(backend.boundInputDeviceUID() == device.uid, "hw: engine bound to the pinned device before the switch")
        _ = setDefaultInputDevice(pinnedID)
        _ = spin(1) { false }
        _ = setDefaultInputDevice(previousDefault)
        expect(spin(6) { backend.isRunning && backend.boundInputDeviceUID() == device.uid },
               "hw: engine is back on the pinned device after a default-input switch and restore")
        lock.lock(); buffers = 0; lock.unlock()
        expect(spin(3) { lock.withCount { buffers } >= 5 }, "hw: buffers flow after the rebind")
    } else {
        print("SKIP  hw default-input switch test (line-in device is already the default input)")
    }

    // stop() must be instant for the caller (the main-thread contract) and
    // still actually stop the engine.
    let stopStart = Date()
    backend.stop()
    expect(Date().timeIntervalSince(stopStart) < 0.2, "hw: stop() returns instantly")
    _ = spin(1) { false }
    expect(!backend.isRunning, "hw: backend reports stopped")

    // WarmCapture lifecycle (serial-mode dictation), attached off-main as
    // in production.
    var warmBuffers = 0
    func warmAttach() -> Bool {
        var ok = false
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            ok = WarmCapture.shared.attach(uid: device.uid) { _ in
                lock.lock(); warmBuffers += 1; lock.unlock()
            }
            done.signal()
        }
        done.wait()
        return ok
    }
    expect(warmAttach(), "hw: warm capture attaches")
    expect(spin(3) { lock.withCount { warmBuffers } >= 5 }, "hw: warm capture buffers flow")
    WarmCapture.shared.detach()
    lock.lock(); warmBuffers = 0; lock.unlock()
    expect(warmAttach(), "hw: warm capture reattaches (reuse path, bounded isRunning probe)")
    expect(spin(3) { lock.withCount { warmBuffers } >= 5 }, "hw: warm capture buffers flow after reuse")
    WarmCapture.shared.detach()
}

/// Spin the main run loop (backend callbacks land on main) until the
/// condition holds or the deadline passes.
private func spin(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return condition()
}

private extension NSLock {
    func withCount(_ body: () -> Int) -> Int {
        lock()
        defer { unlock() }
        return body()
    }
}

/// Self-contained CoreAudio discovery (mirrors InputDeviceSelector's name
/// tiers without widening TingleCore's API): first "line in", else first
/// "cubilux".
private func firstLineInDevice() -> (uid: String, name: String)? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }

    func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // TINGLE_HW_DEVICE=<name substring> picks a specific device (e.g. an
    // adapter not named "line in", like tinker's "USB PnP Audio Device").
    let wanted = ProcessInfo.processInfo.environment["TINGLE_HW_DEVICE"]?.lowercased()
    var fallback: (uid: String, name: String)?
    for id in ids {
        guard let name = stringProperty(id, kAudioObjectPropertyName),
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { continue }
        let lowered = name.lowercased()
        if let wanted {
            if lowered.contains(wanted) { return (uid, name) }
            continue
        }
        if lowered.contains("line in") || lowered.contains("line-in") {
            return (uid, name)
        }
        if fallback == nil, lowered.contains("cubilux") {
            fallback = (uid, name)
        }
    }
    return fallback
}

private func deviceID(forUID uid: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var cfUID = uid as CFString
    var id = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                   UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
    }
    return status == noErr && id != kAudioObjectUnknown ? id : nil
}

private func defaultInputDevice() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
    return status == noErr && id != 0 ? id : nil
}

private func setDefaultInputDevice(_ id: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value = id
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
}
