import Foundation
import TingleCore

func runSendGateTests() {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    let settle = 2.5

    // No fallback ever closed: fire at once.
    expectEqual(SendGate.decide(now: at(1), fallbackClosedAt: nil, lastExternalKeyAt: nil,
                                sendPressedAt: at(1), settleSeconds: settle), .fire, "gate: no fallback fires")
    // Fallback closed long ago: fire at once.
    expectEqual(SendGate.decide(now: at(30), fallbackClosedAt: at(0), lastExternalKeyAt: nil,
                                sendPressedAt: at(30), settleSeconds: settle), .fire, "gate: stale fallback fires")
    // Fallback just closed, nothing typed yet: wait, then give up after settle.
    expectEqual(SendGate.decide(now: at(1), fallbackClosedAt: at(0), lastExternalKeyAt: nil,
                                sendPressedAt: at(1), settleSeconds: settle), .wait, "gate: waits for transcript")
    expectEqual(SendGate.decide(now: at(3.6), fallbackClosedAt: at(0), lastExternalKeyAt: nil,
                                sendPressedAt: at(1), settleSeconds: settle), .fire, "gate: gives up after settle")
    // Typing seen after the close: wait while it is active, fire after 0.5s quiet.
    expectEqual(SendGate.decide(now: at(2.0), fallbackClosedAt: at(0), lastExternalKeyAt: at(1.8),
                                sendPressedAt: at(1), settleSeconds: settle), .wait, "gate: typing still active")
    expectEqual(SendGate.decide(now: at(2.4), fallbackClosedAt: at(0), lastExternalKeyAt: at(1.8),
                                sendPressedAt: at(1), settleSeconds: settle), .fire, "gate: quiet after typing")
    // Typing seen BEFORE the close (the user's own keys) does not count.
    expectEqual(SendGate.decide(now: at(1), fallbackClosedAt: at(0.5), lastExternalKeyAt: at(0.2),
                                sendPressedAt: at(1), settleSeconds: settle), .wait, "gate: pre-close typing ignored")
    // Transcript landed and went quiet before orange was even pressed: immediate.
    expectEqual(SendGate.decide(now: at(5), fallbackClosedAt: at(0), lastExternalKeyAt: at(2),
                                sendPressedAt: at(5), settleSeconds: settle), .fire, "gate: already landed fires")
}
