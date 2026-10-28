import Foundation

/// Pure timing decision for the `send` action (tinker). A fallback
/// transcription app (MacWhisper, Handy) types its transcript a moment
/// AFTER the handle is released; pressing Return before it lands would
/// submit an empty prompt and strand the text. So, within a window after a
/// fallback route closes, send waits: until typing has been quiet for
/// `quietSeconds` once it starts, or `settleSeconds` if it never starts.
/// App routes (Claude's own ⌘D) and built-in dictation finish on release
/// and send fires immediately.
public enum SendGate {
    public enum Decision: Equatable { case fire, wait }

    /// How long after a fallback route closes a send is still considered
    /// "right after dictation".
    public static let windowSeconds: TimeInterval = 10
    /// Typing quiet period that counts as "the transcript has landed".
    public static let quietSeconds: TimeInterval = 0.5

    /// - fallbackClosedAt: when the last fallback route released (nil: never).
    /// - lastExternalKeyAt: last keyDown from another process (nil: none seen).
    /// - sendPressedAt: when the white button was pressed.
    public static func decide(now: Date, fallbackClosedAt: Date?, lastExternalKeyAt: Date?,
                              sendPressedAt: Date, settleSeconds: TimeInterval) -> Decision {
        guard let closed = fallbackClosedAt, now.timeIntervalSince(closed) < windowSeconds else { return .fire }
        if let typed = lastExternalKeyAt, typed > closed {
            // The transcript is (or was) arriving: fire once it goes quiet.
            return now.timeIntervalSince(typed) >= quietSeconds ? .fire : .wait
        }
        // Nothing typed yet: give it a bounded chance, then send anyway.
        return now.timeIntervalSince(sendPressedAt) >= settleSeconds ? .fire : .wait
    }
}
