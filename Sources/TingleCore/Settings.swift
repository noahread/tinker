import AppKit
import Foundation
import os

/// The Settings window's model (tinker). Saved as JSON next to config.toml
/// and layered OVER it as generated TOML: the window owns the app list,
/// the fallback list and the [routing] switches; config.toml keeps
/// vocabulary, replacements, button mappings and anything else.
public struct AppSettings: Codable, Equatable {
    public enum DictationMode: String, Codable, CaseIterable, Identifiable {
        case none, toggle, hold
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .none: return "None (use the fallback)"
            case .toggle: return "Toggle"
            case .hold: return "Hold"
            }
        }
    }

    /// An app with (maybe) its own dictation shortcut and its own send key.
    public struct AppEntry: Codable, Equatable, Identifiable {
        public var bundleId: String
        public var name: String
        public var enabled: Bool
        public var mode: DictationMode
        public var key: String
        public var modifiers: [String]
        public var sendKey: String
        public var sendModifiers: [String]
        public var id: String { bundleId }

        public init(bundleId: String, name: String, enabled: Bool = true, mode: DictationMode = .none,
                    key: String = "", modifiers: [String] = [],
                    sendKey: String = "return", sendModifiers: [String] = []) {
            self.bundleId = bundleId
            self.name = name
            self.enabled = enabled
            self.mode = mode
            self.key = key
            self.modifiers = modifiers
            self.sendKey = sendKey
            self.sendModifiers = sendModifiers
        }
    }

    public enum FallbackKind: String, Codable, CaseIterable, Identifiable {
        case shortcut, shell
        public var id: String { rawValue }
        public var label: String { self == .shortcut ? "Keyboard shortcut" : "Shell command" }
    }

    /// A transcription app that handles any app without its own dictation.
    public struct FallbackEntry: Codable, Equatable, Identifiable {
        public var bundleId: String
        public var name: String
        public var enabled: Bool
        public var kind: FallbackKind
        public var mode: DictationMode      // toggle or hold (shortcut kind)
        public var key: String
        public var modifiers: [String]
        public var shellDown: String
        public var shellUp: String
        public var requireRunning: Bool
        public var id: String { bundleId }

        public init(bundleId: String, name: String, enabled: Bool = true, kind: FallbackKind = .shortcut,
                    mode: DictationMode = .toggle, key: String = "", modifiers: [String] = [],
                    shellDown: String = "", shellUp: String = "", requireRunning: Bool = true) {
            self.bundleId = bundleId
            self.name = name
            self.enabled = enabled
            self.kind = kind
            self.mode = mode
            self.key = key
            self.modifiers = modifiers
            self.shellDown = shellDown
            self.shellUp = shellUp
            self.requireRunning = requireRunning
        }
    }

    public var apps: [AppEntry]
    public var fallbacks: [FallbackEntry]
    public var switchDefaultInput: Bool
    public var showWaveform: Bool
    public var sendKey: String
    public var sendModifiers: [String]
    public var sendSettleSeconds: Double

    public init(apps: [AppEntry], fallbacks: [FallbackEntry], switchDefaultInput: Bool = false,
                showWaveform: Bool = true, sendKey: String = "return", sendModifiers: [String] = [],
                sendSettleSeconds: Double = 2.5) {
        self.apps = apps
        self.fallbacks = fallbacks
        self.switchDefaultInput = switchDefaultInput
        self.showWaveform = showWaveform
        self.sendKey = sendKey
        self.sendModifiers = sendModifiers
        self.sendSettleSeconds = sendSettleSeconds
    }

    // MARK: - Presets

    /// What a fresh Settings window starts from. Disabled entries are
    /// starting points whose shortcut you fill in from that app's settings.
    public static let presets = AppSettings(
        apps: [
            AppEntry(bundleId: "com.anthropic.claudefordesktop", name: "Claude", mode: .toggle, key: "d", modifiers: ["cmd"]),
            AppEntry(bundleId: "com.openai.codex", name: "Codex", mode: .hold, key: "f18"),
            AppEntry(bundleId: "com.openai.chat", name: "ChatGPT", enabled: false, mode: .toggle, key: "f17"),
            AppEntry(bundleId: "com.todesktop.230313mzl4w4u92", name: "Cursor", enabled: false, mode: .none),
            AppEntry(bundleId: "com.apple.mail", name: "Mail", sendKey: "d", sendModifiers: ["cmd", "shift"]),
            AppEntry(bundleId: "com.linear", name: "Linear", sendKey: "return", sendModifiers: ["cmd"]),
        ],
        fallbacks: [
            FallbackEntry(bundleId: "com.goodsnooze.MacWhisper", name: "MacWhisper", mode: .toggle, key: "z", modifiers: ["ctrl"]),
            FallbackEntry(bundleId: "com.pais.handy", name: "Handy", kind: .shell,
                          shellDown: "handy --toggle-transcription", shellUp: "handy --toggle-transcription"),
            FallbackEntry(bundleId: "com.superduper.superwhisper", name: "Superwhisper", enabled: false,
                          mode: .toggle, key: "space", modifiers: ["opt"]),
        ]
    )

    // MARK: - Seeding from the live config

    /// First-run contents: whatever defaults + config.toml currently say,
    /// so opening the window changes nothing, plus the presets' extra
    /// (disabled) entries as starting points.
    public static func seeded(from config: TingConfig) -> AppSettings {
        var apps: [AppEntry] = config.apps.map { id, profile in
            let (mode, key, mods): (DictationMode, String, [String])
            if let d = profile.dictation {
                (mode, key, mods) = (d.mode == .toggle ? .toggle : .hold, d.key, d.modifiers)
            } else {
                (mode, key, mods) = (.none, "", [])
            }
            return AppEntry(bundleId: id, name: profile.name ?? id, mode: mode, key: key, modifiers: mods,
                            sendKey: profile.send?.key ?? "return", sendModifiers: profile.send?.modifiers ?? [])
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for preset in presets.apps where !apps.contains(where: { $0.bundleId == preset.bundleId }) {
            var extra = preset
            extra.enabled = false
            apps.append(extra)
        }
        var fallbacks: [FallbackEntry] = config.fallback.compactMap { profile in
            guard let id = profile.bundleId else { return nil }
            if let d = profile.dictation, profile.triggerDown == nil {
                return FallbackEntry(bundleId: id, name: profile.name ?? id, kind: .shortcut,
                                     mode: d.mode == .toggle ? .toggle : .hold, key: d.key, modifiers: d.modifiers,
                                     requireRunning: profile.requireRunning)
            }
            var down = "", up = ""
            if case .shell(let c)? = profile.triggerDown { down = c }
            if case .shell(let c)? = profile.triggerUp { up = c }
            return FallbackEntry(bundleId: id, name: profile.name ?? id, kind: .shell,
                                 shellDown: down, shellUp: up, requireRunning: profile.requireRunning)
        }
        for preset in presets.fallbacks where !fallbacks.contains(where: { $0.bundleId == preset.bundleId }) {
            var extra = preset
            extra.enabled = false
            fallbacks.append(extra)
        }
        return AppSettings(apps: apps, fallbacks: fallbacks,
                           switchDefaultInput: config.routing.switchDefaultInput,
                           showWaveform: config.routing.showWaveform,
                           sendKey: config.routing.send.key, sendModifiers: config.routing.send.modifiers,
                           sendSettleSeconds: config.routing.sendSettleSeconds)
    }

    // MARK: - TOML overlay

    private static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func tomlList(_ items: [String]) -> String {
        "[" + items.map(tomlString).joined(separator: ", ") + "]"
    }

    private static func chord(key: String, modifiers: [String]) -> String {
        "{ key = \(tomlString(key)), modifiers = \(tomlList(modifiers)) }"
    }

    /// The TOML the config layering applies over defaults + config.toml.
    /// The layering drops the lower layers' `apps` and `fallback` first,
    /// so what this omits (a disabled entry) really is gone; [routing]
    /// merges per key.
    public func tomlOverlay() -> String {
        var out = "# generated by the tinker Settings window - edit there\n\n[routing]\n"
        out += "switchDefaultInput = \(switchDefaultInput)\n"
        out += "showWaveform = \(showWaveform)\n"
        out += "send = \(Self.chord(key: sendKey, modifiers: sendModifiers))\n"
        out += "sendSettleSeconds = \(sendSettleSeconds)\n"
        for app in apps where app.enabled && !app.bundleId.isEmpty {
            out += "\n[apps.\(Self.tomlString(app.bundleId))]\n"
            out += "name = \(Self.tomlString(app.name))\n"
            if app.mode != .none, !app.key.isEmpty {
                out += "dictation = { mode = \(Self.tomlString(app.mode.rawValue)), key = \(Self.tomlString(app.key)), modifiers = \(Self.tomlList(app.modifiers)) }\n"
            }
            if !app.sendKey.isEmpty {
                out += "send = \(Self.chord(key: app.sendKey, modifiers: app.sendModifiers))\n"
            }
        }
        for fb in fallbacks where fb.enabled && !fb.bundleId.isEmpty {
            out += "\n[[fallback]]\n"
            out += "name = \(Self.tomlString(fb.name))\n"
            out += "bundleId = \(Self.tomlString(fb.bundleId))\n"
            out += "requireRunning = \(fb.requireRunning)\n"
            switch fb.kind {
            case .shortcut:
                guard !fb.key.isEmpty else { continue }
                let mode = fb.mode == .none ? DictationMode.toggle : fb.mode
                out += "dictation = { mode = \(Self.tomlString(mode.rawValue)), key = \(Self.tomlString(fb.key)), modifiers = \(Self.tomlList(fb.modifiers)) }\n"
            case .shell:
                if !fb.shellDown.isEmpty {
                    out += "triggerDown = { type = \"shell\", command = \(Self.tomlString(fb.shellDown)) }\n"
                }
                if !fb.shellUp.isEmpty {
                    out += "triggerUp = { type = \"shell\", command = \(Self.tomlString(fb.shellUp)) }\n"
                }
            }
        }
        return out
    }
}

/// Owns settings.json; `save` persists and asks ConfigStore to re-layer.
public final class SettingsStore {
    public static let url = ConfigStore.directoryURL.appendingPathComponent("settings.json")
    private let log = Logger(subsystem: Log.subsystem, category: "settings")

    public init() {}

    public static func load() -> AppSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    /// Saved settings, or on a first run the live config's contents.
    public func current(seedFrom config: TingConfig) -> AppSettings {
        Self.load() ?? .seeded(from: config)
    }

    public func save(_ settings: AppSettings) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: ConfigStore.directoryURL, withIntermediateDirectories: true)
            try encoder.encode(settings).write(to: Self.url, options: .atomic)
            log.info("settings saved")
        } catch {
            log.error("failed to save settings: \(String(describing: error))")
        }
    }

    /// Bundle id, display name and icon of an installed app, for "Add app…".
    public static func appInfo(at url: URL) -> (bundleId: String, name: String)? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return (id, name)
    }

    public static func icon(forBundleId id: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
