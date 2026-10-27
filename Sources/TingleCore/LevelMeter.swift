import AVFoundation
import Accelerate
import Foundation

/// Live input level for the menu bar waveform. Fed from whichever audio
/// tap is running (AudioBackend in audio mode, WarmCapture in serial
/// mode); costs nothing while disarmed. The ring holds the last ~0.7s at
/// ~47 Hz (1024-frame blocks at 48 kHz).
public final class LevelMeter {
    public static let shared = LevelMeter()

    public static let capacity = 32
    private static let blockFrames = 1024
    /// Levels below this are drawn as silence.
    private static let floorDB: Float = -50

    private var armed = false
    private var ring = [Float](repeating: 0, count: LevelMeter.capacity)
    private var head = 0
    private let lock = NSLock()

    public init() {}

    public func arm() {
        lock.lock()
        armed = true
        ring = [Float](repeating: 0, count: Self.capacity)
        head = 0
        lock.unlock()
    }

    public func disarm() {
        lock.lock(); armed = false; lock.unlock()
    }

    public var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return armed
    }

    /// Tap thread. Channel 0 only; stereo adapters carry the ting on both.
    public func ingest(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let on = armed
        lock.unlock()
        guard on, let data = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        var offset = 0
        while offset < frames {
            let n = min(Self.blockFrames, frames - offset)
            var rms: Float = 0
            vDSP_rmsqv(data + offset, 1, &rms, vDSP_Length(n))
            push(Self.normalize(rms: rms))
            offset += n
        }
    }

    public func push(_ level: Float) {
        lock.lock()
        ring[head] = level
        head = (head + 1) % Self.capacity
        lock.unlock()
    }

    /// Oldest first, newest last.
    public func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return Array(ring[head...] + ring[..<head])
    }

    /// RMS -> 0…1 on a dB scale with a -50 dBFS floor. Pure.
    public static func normalize(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db - floorDB) / -floorDB))
    }
}
