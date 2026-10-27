import Foundation
import TingleCore

func runKeyCodesTests() {
    expectEqual(KeyCodes.code(for: "d"), 2, "keys: letter")
    expectEqual(KeyCodes.code(for: "D"), 2, "keys: case-insensitive")
    expectEqual(KeyCodes.code(for: "f13"), 105, "keys: f13")
    expectEqual(KeyCodes.code(for: "f14"), 107, "keys: f14")
    expectEqual(KeyCodes.code(for: "f15"), 113, "keys: f15")
    expectEqual(KeyCodes.code(for: "f16"), 106, "keys: f16")
    expectEqual(KeyCodes.code(for: "f17"), 64, "keys: f17")
    expectEqual(KeyCodes.code(for: "f18"), 79, "keys: f18")
    expectEqual(KeyCodes.code(for: "f19"), 80, "keys: f19")
    expectEqual(KeyCodes.code(for: "f20"), 90, "keys: f20")
    expectEqual(KeyCodes.code(for: "esc"), KeyCodes.code(for: "escape"), "keys: esc alias")
    expectEqual(KeyCodes.code(for: "enter"), KeyCodes.code(for: "return"), "keys: enter alias")
    expectEqual(KeyCodes.code(for: "backspace"), KeyCodes.code(for: "delete"), "keys: backspace alias")
    expectEqual(KeyCodes.code(for: "semicolon"), 41, "keys: punctuation")
    expect(KeyCodes.code(for: "nosuchkey") == nil, "keys: unknown is nil")

    expectEqual(KeyCodes.symbol(key: "d", modifiers: ["cmd"]), "⌘D", "symbol: cmd d")
    expectEqual(KeyCodes.symbol(key: "z", modifiers: ["ctrl"]), "⌃Z", "symbol: ctrl z")
    expectEqual(KeyCodes.symbol(key: "f18", modifiers: []), "F18", "symbol: f18")
    expectEqual(KeyCodes.symbol(key: "space", modifiers: ["opt"]), "⌥Space", "symbol: opt space")
    expectEqual(KeyCodes.symbol(key: "return", modifiers: ["shift", "cmd"]), "⇧⌘↩", "symbol: modifier order")
}
