import Foundation
import TingleCore

func runSettingsTests() {
    // Presets layer over the defaults and own the app/fallback lists.
    do {
        let presets = AppSettings.presets
        let toml = presets.tomlOverlay()
        let config = try! TingConfig.parse(defaults: ConfigStore.defaultTOML, user: "", settings: toml)
        expect(config.apps["com.anthropic.claudefordesktop"]?.dictation ==
               DictationShortcut(mode: .toggle, key: "d", modifiers: ["cmd"]), "settings: claude preset applied")
        expect(config.apps["com.openai.chat"] == nil, "settings: disabled preset is absent")
        expect(config.apps["com.linear"]?.send == KeyChord(key: "return", modifiers: ["cmd"]), "settings: send-only app kept")
        expectEqual(config.fallback.map { $0.name ?? "" }, ["MacWhisper", "Handy"], "settings: enabled fallbacks in order")
        expectEqual(config.fallback[1].triggerDown, .shell(command: "handy --toggle-transcription"), "settings: shell fallback")
        expect(config.vocabulary.count > 100, "settings: lower layers untouched")
        expectEqual(config.mappings["white"], .send, "settings: button mappings untouched")
    }
    // Disabling / reordering / general switches round-trip through the overlay.
    do {
        var s = AppSettings.presets
        s.apps[0].enabled = false                      // Claude off
        s.fallbacks.swapAt(0, 1)                       // Handy first
        s.switchDefaultInput = true
        s.sendKey = "return"; s.sendModifiers = ["cmd"]
        s.sendSettleSeconds = 4
        let config = try! TingConfig.parse(defaults: ConfigStore.defaultTOML, user: "", settings: s.tomlOverlay())
        expect(config.apps["com.anthropic.claudefordesktop"] == nil, "settings: disabled app removed even though defaults ship it")
        expectEqual(config.fallback.first?.name, "Handy", "settings: fallback order follows the window")
        expect(config.routing.switchDefaultInput, "settings: input switch")
        expectEqual(config.routing.send, KeyChord(key: "return", modifiers: ["cmd"]), "settings: default send chord")
        expectEqual(config.routing.sendSettleSeconds, 4, "settings: settle seconds")
        let route = RouteResolver.resolve(frontmost: "com.anthropic.claudefordesktop",
                                          running: ["com.pais.handy"], config: config)
        expectEqual(route.name, "Handy", "settings: disabled app falls through to the fallback")
    }
    // An app with mode .none but a send key: no dictation, send still applies.
    do {
        var s = AppSettings.presets
        s.apps[3].enabled = true   // Cursor, mode none
        s.apps[3].sendKey = "return"; s.apps[3].sendModifiers = ["cmd"]
        let config = try! TingConfig.parse(defaults: ConfigStore.defaultTOML, user: "", settings: s.tomlOverlay())
        let id = "com.todesktop.230313mzl4w4u92"
        expect(config.apps[id]?.dictation == nil, "settings: mode none writes no dictation")
        expectEqual(RouteResolver.sendChord(frontmost: id, config: config), KeyChord(key: "return", modifiers: ["cmd"]), "settings: send chord for a no-dictation app")
        expectEqual(RouteResolver.resolve(frontmost: id, running: [], config: config).kind, .builtin, "settings: no-dictation app routes to fallback/builtin")
    }
    // Quoting: names and commands with quotes survive the generated TOML.
    do {
        var s = AppSettings(apps: [], fallbacks: [])
        s.fallbacks = [AppSettings.FallbackEntry(bundleId: "x.y", name: "Say \"hi\"", kind: .shell,
                                                 shellDown: "echo \"down\" && echo 'ok'", shellUp: "")]
        let config = try! TingConfig.parse(defaults: ConfigStore.defaultTOML, user: "", settings: s.tomlOverlay())
        expectEqual(config.fallback.first?.name, "Say \"hi\"", "settings: quotes in names")
        expectEqual(config.fallback.first?.triggerDown, .shell(command: "echo \"down\" && echo 'ok'"), "settings: quotes in commands")
        expect(config.fallback.first?.triggerUp == nil, "settings: empty up command omitted")
        expect(config.apps.isEmpty, "settings: empty app list drops the shipped apps")
    }
    // JSON round trip.
    do {
        let data = try! JSONEncoder().encode(AppSettings.presets)
        let back = try! JSONDecoder().decode(AppSettings.self, from: data)
        expectEqual(back, AppSettings.presets, "settings: JSON round trip")
    }
    // Seeding from the live config keeps the user's config.toml choices.
    do {
        let config = try! TingConfig.parse(defaults: ConfigStore.defaultTOML, user: """
        [routing]
        switchDefaultInput = true
        [apps."com.apple.Safari"]
        name = "Safari"
        dictation = { mode = "hold", key = "f19" }
        """)
        let seeded = AppSettings.seeded(from: config)
        expect(seeded.switchDefaultInput, "seed: routing switch carried over")
        let safari = seeded.apps.first { $0.bundleId == "com.apple.Safari" }
        expectEqual(safari?.mode, .hold, "seed: user app mode")
        expectEqual(safari?.key, "f19", "seed: user app key")
        expect(seeded.apps.first { $0.bundleId == "com.openai.chat" }?.enabled == false, "seed: preset extras arrive disabled")
        expectEqual(seeded.fallbacks.prefix(2).map(\.name), ["MacWhisper", "Handy"], "seed: shipped fallbacks in order")
        expectEqual(seeded.fallbacks[1].kind, .shell, "seed: shell fallback recognised")
        // Round trip: seeding then overlaying reproduces the same routing.
        let again = try! TingConfig.parse(defaults: ConfigStore.defaultTOML, user: "", settings: seeded.tomlOverlay())
        expectEqual(again.apps["com.apple.Safari"]?.dictation, DictationShortcut(mode: .hold, key: "f19"), "seed: overlay reproduces the app")
        expect(again.routing.switchDefaultInput, "seed: overlay reproduces the switch")
    }
}
