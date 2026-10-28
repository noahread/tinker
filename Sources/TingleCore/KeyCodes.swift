import CoreGraphics
import Foundation

/// Key names accepted in config actions (`key = "f18"`, `key = "d"`) and
/// their ANSI-US virtual key codes. Public so the routing layer and the
/// tests can resolve and render shortcuts without going through
/// ActionRunner (which needs Accessibility to do anything).
public enum KeyCodes {
    public static let byName: [String: CGKeyCode] = [
        // Named keys
        "return": 36, "enter": 36, "escape": 53, "esc": 53, "space": 49,
        "tab": 48, "delete": 51, "backspace": 51, "forwarddelete": 117,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        // Letters
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31,
        "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9,
        "w": 13, "x": 7, "y": 16, "z": 6,
        // Digits
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
        "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        // Punctuation
        "minus": 27, "equal": 24, "leftbracket": 33, "rightbracket": 30,
        "backslash": 42, "semicolon": 41, "quote": 39, "comma": 43,
        "period": 47, "slash": 44, "grave": 50,
        // Function keys. f13-f20 are the classic "unused" keys that
        // dictation apps (Codex, MacWhisper, Handy) are happy to bind.
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64,
        "f18": 79, "f19": 80, "f20": 90,
    ]

    public static func code(for key: String) -> CGKeyCode? {
        byName[key.lowercased()]
    }

    /// Keys in the keyboard's function block. macOS stamps real presses of
    /// these with the secondary-fn flag, and some apps (Codex's global
    /// dictation hold key) only match when that flag is present.
    public static func isFunctionBlockKey(_ key: String) -> Bool {
        let k = key.lowercased()
        if k.hasPrefix("f"), let n = Int(k.dropFirst()), (1...20).contains(n) { return true }
        return ["left", "right", "up", "down", "home", "end", "pageup", "pagedown", "forwarddelete"].contains(k)
    }

    /// Menu-friendly rendering in macOS order: ⌃⌥⇧⌘ then the key
    /// ("⌘D", "⌃Z", "F18", "⌥Space").
    public static func symbol(key: String, modifiers: [String]) -> String {
        var out = ""
        let mods = Set(modifiers.map { $0.lowercased() })
        if mods.contains("fn") || mods.contains("function") { out += "fn" }
        if mods.contains("ctrl") || mods.contains("control") { out += "⌃" }
        if mods.contains("opt") || mods.contains("option") || mods.contains("alt") { out += "⌥" }
        if mods.contains("shift") { out += "⇧" }
        if mods.contains("cmd") || mods.contains("command") { out += "⌘" }
        let k = key.lowercased()
        switch k {
        case "return", "enter": out += "↩"
        case "escape", "esc": out += "⎋"
        case "space": out += "Space"
        case "tab": out += "⇥"
        case "delete", "backspace": out += "⌫"
        case "left": out += "←"
        case "right": out += "→"
        case "up": out += "↑"
        case "down": out += "↓"
        default:
            if k.count == 1 { out += k.uppercased() }
            else if k.hasPrefix("f"), Int(k.dropFirst()) != nil { out += k.uppercased() }
            else { out += k }
        }
        return out
    }
}
