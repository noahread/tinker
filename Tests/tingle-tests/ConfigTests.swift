import Foundation
import TingleCore

func runConfigTests() {
    do { // tinker routing tables ship in the defaults and layer per app
        let config = try! TingConfig.parse(toml: ConfigStore.defaultTOML)
        expect(config.routing.enabled, "routing: enabled by default")
        expect(!config.routing.switchDefaultInput, "routing: input switch off by default")
        expect(config.routing.showWaveform, "routing: waveform on by default")
        expectEqual(config.apps.count, 4, "routing: four app profiles shipped")
        expectEqual(config.apps["com.anthropic.claudefordesktop"]?.dictation,
                    DictationShortcut(mode: .toggle, key: "d", modifiers: ["cmd"]), "routing: claude profile")
        expectEqual(config.apps["com.openai.codex"]?.dictation,
                    DictationShortcut(mode: .hold, key: "f18"), "routing: codex hold profile")
        expectEqual(config.fallback.map { $0.name ?? "" }, ["MacWhisper", "Handy"], "routing: fallback order")
        expect(config.fallback.allSatisfy { $0.requireRunning }, "routing: fallbacks require running")

        let overlay = try! TingConfig.parse(defaults: ConfigStore.defaultTOML, user: """
        [apps."com.apple.Safari"]
        name = "Safari"
        dictation = { mode = "toggle", key = "f17" }
        """)
        expectEqual(overlay.apps.count, 5, "routing: user app table merges per app")
        expect(overlay.apps["com.anthropic.claudefordesktop"] != nil, "routing: defaults survive app overlay")

        let replaced = try! TingConfig.parse(defaults: ConfigStore.defaultTOML, user: """
        [[fallback]]
        name = "Only"
        bundleId = "x.y"
        dictation = { mode = "hold", key = "f13" }
        """)
        expectEqual(replaced.fallback.count, 1, "routing: user fallback list replaces wholesale")

        let disabled = try! TingConfig.parse(defaults: ConfigStore.defaultTOML, user: "[routing]\nenabled = false\n")
        expect(!disabled.routing.enabled, "routing: can be disabled")

        expect((try? TingConfig.parse(toml: """
        [apps."a.b"]
        dictation = { mode = "bogus", key = "d" }
        """)) == nil, "routing: unknown dictation mode is a parse error")
    }
    do { // the shipped literate default template must parse to the defaults
        let config = try! TingConfig.parse(toml: ConfigStore.defaultTOML)
        expectEqual(config.toneFrequencies, [17500, 18000, 18500, 19000], "config: default frequencies")
        expect(config.vocabulary.count > 100, "config: generous default vocabulary")
        expect(config.vocabulary.contains("TOML"), "config: TOML never Tamil again")
        expect(config.vocabulary.contains("Claude"), "config: Claude in vocabulary")
        expect(config.vocabulary.contains("subagent"), "config: agentic terms present")
        expect(config.extraVocabulary.isEmpty, "config: defaults ship no extra vocabulary")
        expectEqual(config.effectiveVocabulary, config.vocabulary,
                    "config: effective vocabulary is builtin when extras empty")
        expectEqual(config.mappings["triggerDown"], .dictate, "config: default trigger mapping")
        expectEqual(config.mappings["modeChange"], .eraseDictation, "config: default green mapping")
        expectEqual(config.mappings["fxChange"], .send, "config: default orange mapping is send")
        expectEqual(config.routing.send, KeyChord(key: "return"), "config: default send chord is return")
        expectEqual(config.routing.sendSettleSeconds, 2.5, "config: default send settle")
        expectEqual(config.apps["com.linear"]?.send, KeyChord(key: "return", modifiers: ["cmd"]), "config: linear sends cmd+return")
        expect(config.mappings["mode1"] == nil, "config: no per-mode white mappings by default")
        if case .shell(let cmd)? = config.mappings["white"] {
            expect(cmd.contains("is running") && cmd.contains("activate"),
                   "config: white catch-all is the summon script")
        } else {
            expect(false, "config: white catch-all mapped by default")
        }
        expectEqual(config.action(for: .whitePress(mode: 3)), config.mappings["white"],
                    "config: whitePress falls back to the white catch-all")
    }
    do { // layered parse: user file overlays defaults with per-key precedence
        let empty = try! TingConfig.parse(defaults: ConfigStore.defaultTOML, user: "")
        expectEqual(empty.effectiveVocabulary, TingConfig.default.effectiveVocabulary,
                    "layering: empty user file yields pure defaults")
        expectEqual(empty.mappings["triggerDown"], .dictate, "layering: default mappings survive empty overlay")

        let starter = try! TingConfig.parse(defaults: ConfigStore.defaultTOML,
                                            user: ConfigStore.userTemplateTOML)
        expectEqual(starter.effectiveVocabulary, TingConfig.default.effectiveVocabulary,
                    "layering: starter template changes nothing")

        let overlay = try! TingConfig.parse(defaults: ConfigStore.defaultTOML, user: """
        extraVocabulary = ["Metabase", "TOML"]

        [rewrite]
        enabled = true

        [mappings]
        mode1 = { type = "keystroke", key = "escape" }
        fxChange = { type = "keystroke", key = "tab" }
        """)
        // section tables merge per key: the one switched key changes...
        expect(overlay.rewrite.enabled, "layering: user rewrite.enabled wins")
        // ...and untouched keys still come from defaults, not decode zeroes.
        expect(overlay.rewrite.removeFillers, "layering: untouched rewrite keys keep defaults")
        expect(overlay.rewrite.correctVocabulary, "layering: untouched rewrite keys keep defaults 2")
        expectEqual(overlay.mappings["mode1"], .keystroke(key: "escape", modifiers: []),
                    "layering: new mapping added")
        expectEqual(overlay.mappings["triggerDown"], .dictate,
                    "layering: unmentioned mappings survive")
        // inline action tables replace WHOLESALE - no field bleed-through
        // from the default action into the user's replacement.
        expectEqual(overlay.mappings["fxChange"], .keystroke(key: "tab", modifiers: []),
                    "layering: overridden mapping replaced wholesale")
        // extraVocabulary concatenates after the builtin list, deduped.
        expect(overlay.effectiveVocabulary.contains("Metabase"), "layering: extra vocabulary appended")
        expectEqual(overlay.effectiveVocabulary.filter { $0 == "TOML" }.count, 1,
                    "layering: effective vocabulary dedupes")
        expect(overlay.effectiveVocabulary.count > 100, "layering: builtin vocabulary retained")

        // a user list key overrides wholesale - the documented escape hatch.
        let replaced = try! TingConfig.parse(defaults: ConfigStore.defaultTOML, user: """
        vocabulary = ["OnlyWord"]
        """)
        expectEqual(replaced.effectiveVocabulary, ["OnlyWord"],
                    "layering: user vocabulary key discards builtins wholesale")
    }
    do { // multiline embedded script + all action types
        let toml = """
        vocabulary = ["Cubilux"]

        [mappings]
        mode1 = { type = "shell", command = '''
        for app in "Claude" "Codex"; do
          open -a "$app" && exit 0
        done
        ''' }
        mode2 = { type = "keystroke", key = "escape", modifiers = ["cmd", "shift"] }
        triggerDown = { type = "keyHold", key = "f5" }
        """
        let config = try! TingConfig.parse(toml: toml)
        guard case .shell(let command)? = config.mappings["mode1"] else {
            expect(false, "config: multiline shell parses"); return
        }
        expect(command.contains("open -a \"$app\""), "config: multiline script content")
        expect(command.contains("\n"), "config: script is genuinely multiline")
        expectEqual(config.mappings["mode2"], .keystroke(key: "escape", modifiers: ["cmd", "shift"]),
                    "config: keystroke with modifiers")
        expectEqual(config.mappings["triggerDown"], .keyHold(key: "f5", modifiers: []),
                    "config: keyHold defaults empty modifiers")
        expectEqual(config.vocabulary, ["Cubilux"], "config: vocabulary list")
        expectEqual(config.toneFrequencies, [17500, 18000, 18500, 19000],
                    "config: omitted frequencies fall back to defaults")
    }
    do { // unknown action type is a hard parse error (typo safety)
        let bad = """
        [mappings]
        mode1 = { type = "keystorke", key = "a" }
        """
        expect((try? TingConfig.parse(toml: bad)) == nil, "config: unknown action type rejected")
    }
}

func runBatteryEstimateTests() {
    expectEqual(BatteryEstimate.percent(packVolts: 3.2), 100, "battery: fresh pack")
    expectEqual(BatteryEstimate.percent(packVolts: 1.9), 0, "battery: dead pack")
    expect(BatteryEstimate.percent(packVolts: 3.0) > 60, "battery: 1.5V/cell reads healthy")
    expect((20...60).contains(BatteryEstimate.percent(packVolts: 2.45)), "battery: mid-plateau plausible")
    // monotonic: more volts never reads as less charge
    var last = -1
    for mv in stride(from: 1800, through: 3300, by: 10) {
        let p = BatteryEstimate.percent(packVolts: Double(mv) / 1000)
        expect(p >= last, "battery: monotonic at \(mv)mV")
        last = p
    }
}

func runReplacementTests() {
    let map = ["Tamil": "TOML", "clod": "Claude"]
    expectEqual(TingConfig.applyReplacements("commit the Tamil file", map),
                "commit the TOML file", "replacements: basic word swap")
    expectEqual(TingConfig.applyReplacements("Tamil, Tamil!", map),
                "TOML, TOML!", "replacements: punctuation boundaries")
    expectEqual(TingConfig.applyReplacements("Tamilnadu is a state", map),
                "Tamilnadu is a state", "replacements: no partial-word hits")
    expectEqual(TingConfig.applyReplacements("ask clod about it", map),
                "ask Claude about it", "replacements: second rule")
    expectEqual(TingConfig.applyReplacements("nothing to do", [:]),
                "nothing to do", "replacements: empty map is identity")

    let config = try! TingConfig.parse(toml: ConfigStore.defaultTOML)
    expectEqual(config.replacements["Tamil"], "TOML", "config: default Tamil->TOML rule")
    expectEqual(config.replacements["clawed"], "Claude", "config: default clawed->Claude rule")
    expectEqual(TingConfig.applyReplacements("open clawed code", config.replacements),
                "open Claude code", "replacements: clawed corrected in context")
}


func runWhiteFallbackTests() {
    let toml = """
    [mappings]
    white = { type = "keystroke", key = "escape" }
    mode2 = { type = "keystroke", key = "space" }
    """
    let config = try! TingConfig.parse(toml: toml)
    expectEqual(config.action(for: .whitePress(mode: 2)), .keystroke(key: "space", modifiers: []),
                "white fallback: specific mode wins")
    expectEqual(config.action(for: .whitePress(mode: 1)), .keystroke(key: "escape", modifiers: []),
                "white fallback: catch-all covers unmapped modes")
    expectEqual(config.action(for: .modeChanged(mode: 1)), nil,
                "white fallback: catch-all never leaks to other events")
}
