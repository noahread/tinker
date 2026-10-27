import Foundation
import TingleCore

func runRouteResolverTests() {
    let claude = "com.anthropic.claudefordesktop"
    let codex = "com.openai.codex"
    let macwhisper = "com.goodsnooze.MacWhisper"
    let handy = "com.pais.handy"
    let safari = "com.apple.Safari"
    let config = TingConfig.default   // shipped defaults: Claude, Codex, MacWhisper, Handy

    // 1. Claude frontmost -> its own ⌘D toggle, both ways.
    do {
        let r = RouteResolver.resolve(frontmost: claude, running: [claude], config: config)
        expectEqual(r.kind, .app, "route: claude is an app route")
        expectEqual(r.name, "Claude", "route: claude name")
        expectEqual(r.down, .keystroke(key: "d", modifiers: ["cmd"]), "route: claude down")
        expectEqual(r.up, .keystroke(key: "d", modifiers: ["cmd"]), "route: claude up")
        expectEqual(r.summary, "⌘D (toggle)", "route: claude summary")
        expectEqual(RouteResolver.describe(r), "Claude → ⌘D (toggle)", "route: describe app")
    }
    // 2. Codex hold profile -> keyHold down, nothing up.
    do {
        let r = RouteResolver.resolve(frontmost: codex, running: [codex], config: config)
        expectEqual(r.down, .keyHold(key: "f18", modifiers: []), "route: codex hold down")
        expect(r.up == nil, "route: hold has no up action")
        expectEqual(r.summary, "F18 (hold)", "route: codex summary")
    }
    // 3. Explicit triggerDown overrides the dictation sugar.
    do {
        let profile = AppProfile(name: "X", dictation: DictationShortcut(mode: .toggle, key: "d", modifiers: ["cmd"]),
                                 triggerDown: .shell(command: "echo down"))
        let (down, up) = RouteResolver.actions(for: profile)
        expectEqual(down, .shell(command: "echo down"), "route: explicit down wins")
        expectEqual(up, .keystroke(key: "d", modifiers: ["cmd"]), "route: derived up kept")
        // keyHold / dictate are press-only and must be dropped from up.
        let bad = AppProfile(triggerDown: .keystroke(key: "a", modifiers: []), triggerUp: .keyHold(key: "a", modifiers: []))
        expect(RouteResolver.actions(for: bad).up == nil, "route: keyHold on up is dropped")
    }
    // 4. Safari frontmost, MacWhisper running -> fallback ⌃Z toggle.
    do {
        let r = RouteResolver.resolve(frontmost: safari, running: [safari, macwhisper], config: config)
        expectEqual(r.kind, .fallback, "route: fallback kind")
        expectEqual(r.name, "MacWhisper", "route: macwhisper chosen")
        expectEqual(r.bundleId, macwhisper, "route: macwhisper bundle")
        expectEqual(r.down, .keystroke(key: "z", modifiers: ["ctrl"]), "route: macwhisper down")
        expectEqual(r.up, .keystroke(key: "z", modifiers: ["ctrl"]), "route: macwhisper up")
        expect(r.requireRunning, "route: fallback requires running")
        expectEqual(RouteResolver.describe(r), "MacWhisper → ⌃Z (toggle)", "route: describe fallback")
    }
    // 5. MacWhisper not running, Handy running -> Handy (order respected).
    do {
        let r = RouteResolver.resolve(frontmost: safari, running: [safari, handy], config: config)
        expectEqual(r.name, "Handy", "route: handy when macwhisper absent")
        expectEqual(r.down, .shell(command: "handy --toggle-transcription"), "route: handy down shell")
        expectEqual(r.up, .shell(command: "handy --toggle-transcription"), "route: handy up shell")
        expectEqual(r.summary, "shell", "route: handy summary")
    }
    // 6. requireRunning = false entry is chosen while not running.
    do {
        var c = config
        c.fallback = [AppProfile(name: "Always", bundleId: "x.y", requireRunning: false,
                                 dictation: DictationShortcut(mode: .hold, key: "f19"))]
        let r = RouteResolver.resolve(frontmost: safari, running: [], config: c)
        expectEqual(r.name, "Always", "route: requireRunning=false chosen")
        expect(!r.requireRunning, "route: requireRunning flag carried")
    }
    // 7. Nothing running -> builtin dictation.
    do {
        let r = RouteResolver.resolve(frontmost: safari, running: [safari], config: config)
        expectEqual(r.kind, .builtin, "route: builtin kind")
        expectEqual(r.down, .dictate, "route: builtin down is dictate")
        expect(r.up == nil, "route: builtin up nil")
        expect(r.usesBuiltinDictation, "route: builtin flag")
        expectEqual(RouteResolver.describe(r), "built-in dictation", "route: describe builtin")
    }
    // 8. Unknown frontmost -> fallback path.
    do {
        let r = RouteResolver.resolve(frontmost: nil, running: [macwhisper], config: config)
        expectEqual(r.name, "MacWhisper", "route: nil frontmost uses fallback")
    }
    // 9. routing.enabled = false -> builtin even with Claude in front.
    do {
        var c = config
        c.routing.enabled = false
        let r = RouteResolver.resolve(frontmost: claude, running: [claude, macwhisper], config: c)
        expectEqual(r.kind, .builtin, "route: disabled routing is builtin")
    }
    // 10. Empty app profile falls through to the fallback.
    do {
        var c = config
        c.apps[safari] = AppProfile(name: "Safari")
        let r = RouteResolver.resolve(frontmost: safari, running: [macwhisper], config: c)
        expectEqual(r.name, "MacWhisper", "route: empty profile falls through")
    }
    // 11. RouteSession: once per press; app quits mid-hold; duplicate press.
    do {
        var s = RouteSession()
        let r = RouteResolver.resolve(frontmost: safari, running: [macwhisper], config: config)
        expectEqual(s.press(r), r.down, "session: press returns down")
        expect(s.press(r) == nil, "session: duplicate press is a no-op")
        expectEqual(s.release(running: [macwhisper]), r.up, "session: release returns up once")
        expect(s.release(running: [macwhisper]) == nil, "session: second release nil")
        _ = s.press(r)
        expect(s.release(running: []) == nil, "session: fallback app gone -> no up")
        expect(s.active == nil, "session: cleared after release")
        let app = RouteResolver.resolve(frontmost: claude, running: [], config: config)
        _ = s.press(app)
        expectEqual(s.release(running: []), app.up, "session: app routes close even if not running")
    }
}
