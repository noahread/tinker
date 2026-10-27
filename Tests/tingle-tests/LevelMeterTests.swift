import Foundation
import TingleCore

func runLevelMeterTests() {
    expectEqual(LevelMeter.normalize(rms: 0), 0, "meter: silence is 0")
    expectEqual(LevelMeter.normalize(rms: 1), 1, "meter: full scale is 1")
    expect(LevelMeter.normalize(rms: 0.0001) == 0, "meter: below the floor clamps to 0")
    let quiet = LevelMeter.normalize(rms: 0.01)
    let loud = LevelMeter.normalize(rms: 0.1)
    expect(quiet > 0 && quiet < loud && loud < 1, "meter: monotonic on a dB scale")
    expect(abs(loud - 0.6) < 0.01, "meter: -20 dBFS lands at 0.6 with a -50 dB floor")

    let m = LevelMeter()
    m.arm()
    for i in 0..<(LevelMeter.capacity + 5) { m.push(Float(i)) }
    let snap = m.snapshot()
    expectEqual(snap.count, LevelMeter.capacity, "meter: ring keeps capacity")
    expectEqual(snap.first, 5, "meter: oldest first")
    expectEqual(snap.last, Float(LevelMeter.capacity + 4), "meter: newest last")
    m.disarm()
    expect(!m.isArmed, "meter: disarm")
    m.arm()
    expect(m.snapshot().allSatisfy { $0 == 0 }, "meter: arm clears the ring")
}
