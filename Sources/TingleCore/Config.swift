import Foundation
import TOMLKit
import os

/// A user-configured action fired when a ting event is detected.
public enum TingAction: Equatable {
    case keystroke(key: String, modifiers: [String])
    case shell(command: String)
    /// Posts key-DOWN only and keeps the key held; the matching key-UP is
    /// posted when triggerUp fires (or on quit). Meant for the triggerDown
    /// mapping — enables hold-to-dictate hotkeys.
    case keyHold(key: String, modifiers: [String])
    /// Native live dictation (SpeechAnalyzer, macOS 26): triggerDown starts
    /// transcribing the ting's mic and types into the frontmost app live;
    /// triggerUp finalizes. Valid ONLY on the triggerDown mapping.
    case dictate
    /// Erase the last completed dictation take (repeat presses peel back
    /// earlier takes). Default on the green button (modeChange).
    case eraseDictation
    /// tinker: submit what was dictated using the frontmost app's send
    /// shortcut (`[apps."…"] send`, else `[routing] send`, default ↩).
    /// Waits briefly for a late-arriving transcript from a fallback
    /// transcription app. Default on the orange button (fxChange).
    case send

    /// Short human-readable description (menu display).
    public var summary: String {
        switch self {
        case .keystroke(let key, let modifiers):
            return "keystroke: " + (modifiers + [key]).joined(separator: "+")
        case .shell(let command):
            return "shell: \(command)"
        case .keyHold(let key, let modifiers):
            return "keyHold: " + (modifiers + [key]).joined(separator: "+")
        case .dictate:
            return "dictate (live transcription)"
        case .eraseDictation:
            return "erase last dictation"
        case .send:
            return "send (app's submit shortcut)"
        }
    }
}

extension TingAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, key, modifiers, command
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "keystroke":
            self = .keystroke(
                key: try container.decode(String.self, forKey: .key),
                modifiers: try container.decodeIfPresent([String].self, forKey: .modifiers) ?? []
            )
        case "shell":
            self = .shell(command: try container.decode(String.self, forKey: .command))
        case "keyHold":
            self = .keyHold(
                key: try container.decode(String.self, forKey: .key),
                modifiers: try container.decodeIfPresent([String].self, forKey: .modifiers) ?? []
            )
        case "dictate":
            self = .dictate
        case "eraseDictation":
            self = .eraseDictation
        case "send":
            self = .send
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "unknown action type \"\(type)\" (expected \"keystroke\", \"shell\", \"keyHold\", \"dictate\", \"eraseDictation\" or \"send\")"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keystroke(let key, let modifiers):
            try container.encode("keystroke", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(modifiers, forKey: .modifiers)
        case .shell(let command):
            try container.encode("shell", forKey: .type)
            try container.encode(command, forKey: .command)
        case .keyHold(let key, let modifiers):
            try container.encode("keyHold", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(modifiers, forKey: .modifiers)
        case .dictate:
            try container.encode("dictate", forKey: .type)
        case .eraseDictation:
            try container.encode("eraseDictation", forKey: .type)
        case .send:
            try container.encode("send", forKey: .type)
        }
    }
}

/// The user's configuration, parsed from literate TOML. TOML has no null,
/// so an unmapped input is simply an absent key; every field is optional
/// with sensible defaults.
/// Post-dictation LLM rewrite pass (Apple's on-device Foundation model).
/// Every bool maps to a fixed prompt fragment; `customInstructions` is the
/// only freeform field and is appended last. All inert unless `enabled`.
public struct RewriteConfig: Decodable, Equatable {
    public var enabled = true
    public var removeFillers = true
    public var fixPunctuation = true
    public var fixGrammar = false
    public var correctVocabulary = true
    public var technicalFormatting = true
    public var customInstructions = ""

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, removeFillers, fixPunctuation, fixGrammar,
             correctVocabulary, technicalFormatting, customInstructions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers) ?? true
        fixPunctuation = try c.decodeIfPresent(Bool.self, forKey: .fixPunctuation) ?? true
        fixGrammar = try c.decodeIfPresent(Bool.self, forKey: .fixGrammar) ?? false
        correctVocabulary = try c.decodeIfPresent(Bool.self, forKey: .correctVocabulary) ?? true
        technicalFormatting = try c.decodeIfPresent(Bool.self, forKey: .technicalFormatting) ?? true
        customInstructions = try c.decodeIfPresent(String.self, forKey: .customInstructions) ?? ""
    }
}

/// A plain key chord (`{ key = "return", modifiers = ["cmd"] }`).
public struct KeyChord: Decodable, Equatable {
    public var key: String
    public var modifiers: [String]

    public init(key: String, modifiers: [String] = []) {
        self.key = key
        self.modifiers = modifiers
    }

    private enum CodingKeys: String, CodingKey { case key, modifiers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        modifiers = try c.decodeIfPresent([String].self, forKey: .modifiers) ?? []
    }

    public var symbol: String { KeyCodes.symbol(key: key, modifiers: modifiers) }
    public var keystroke: TingAction { .keystroke(key: key, modifiers: modifiers) }
}

/// How an app's own dictation is driven from the handle. `toggle` presses
/// the chord on squeeze and again on release (Claude ⌘D, MacWhisper in
/// toggle mode); `hold` holds the chord down for the whole squeeze
/// (push-to-talk hotkeys: Codex "press to dictate", MacWhisper/Handy in
/// hold mode).
public struct DictationShortcut: Decodable, Equatable {
    public enum Mode: String, Decodable { case toggle, hold }
    public var mode: Mode
    public var key: String
    public var modifiers: [String]

    public init(mode: Mode, key: String, modifiers: [String] = []) {
        self.mode = mode
        self.key = key
        self.modifiers = modifiers
    }

    private enum CodingKeys: String, CodingKey { case mode, key, modifiers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(Mode.self, forKey: .mode)
        key = try c.decode(String.self, forKey: .key)
        modifiers = try c.decodeIfPresent([String].self, forKey: .modifiers) ?? []
    }

    /// "⌘D (toggle)", "F18 (hold)".
    public var summary: String {
        "\(KeyCodes.symbol(key: key, modifiers: modifiers)) (\(mode.rawValue))"
    }
}

/// One routing target: an app with its own dictation (`[apps."<bundle id>"]`)
/// or a fallback transcription app (`[[fallback]]`). Either describe the
/// shortcut with `dictation` or give explicit `triggerDown`/`triggerUp`
/// actions (explicit keys win over the derived ones).
public struct AppProfile: Decodable, Equatable {
    public var name: String?
    public var bundleId: String?
    /// Fallback entries only: skip this entry unless the app is running.
    public var requireRunning: Bool
    public var dictation: DictationShortcut?
    public var triggerDown: TingAction?
    public var triggerUp: TingAction?
    /// This app's submit shortcut for the `send` action (default: `[routing] send`).
    public var send: KeyChord?

    public init(name: String? = nil, bundleId: String? = nil, requireRunning: Bool = true,
                dictation: DictationShortcut? = nil,
                triggerDown: TingAction? = nil, triggerUp: TingAction? = nil,
                send: KeyChord? = nil) {
        self.name = name
        self.bundleId = bundleId
        self.requireRunning = requireRunning
        self.dictation = dictation
        self.triggerDown = triggerDown
        self.triggerUp = triggerUp
        self.send = send
    }

    private enum CodingKeys: String, CodingKey {
        case name, bundleId, requireRunning, dictation, triggerDown, triggerUp, send
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
        requireRunning = try c.decodeIfPresent(Bool.self, forKey: .requireRunning) ?? true
        dictation = try c.decodeIfPresent(DictationShortcut.self, forKey: .dictation)
        triggerDown = try c.decodeIfPresent(TingAction.self, forKey: .triggerDown)
        triggerUp = try c.decodeIfPresent(TingAction.self, forKey: .triggerUp)
        send = try c.decodeIfPresent(KeyChord.self, forKey: .send)
    }
}

/// `[routing]`: the per-app routing switchboard. All inert when `enabled`
/// is false (upstream tingle behaviour: `[mappings]` only).
public struct RoutingConfig: Decodable, Equatable {
    public var enabled = true
    /// Make the ting's capture device the system default input while the
    /// handle is held, so the external app records the ting's mic.
    public var switchDefaultInput = false
    public var showWaveform = true
    /// Submit shortcut for apps without their own `send`.
    public var send = KeyChord(key: "return")
    /// After a fallback transcription app finishes, how long `send` will
    /// wait for its transcript to START arriving before giving up and
    /// sending anyway. Once typing is seen, send fires after 0.5s of quiet.
    public var sendSettleSeconds: Double = 2.5

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, switchDefaultInput, showWaveform, send, sendSettleSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        switchDefaultInput = try c.decodeIfPresent(Bool.self, forKey: .switchDefaultInput) ?? false
        showWaveform = try c.decodeIfPresent(Bool.self, forKey: .showWaveform) ?? true
        send = try c.decodeIfPresent(KeyChord.self, forKey: .send) ?? KeyChord(key: "return")
        sendSettleSeconds = try c.decodeIfPresent(Double.self, forKey: .sendSettleSeconds) ?? 2.5
    }
}

public struct TingConfig: Decodable {
    /// The four mode tone frequencies (Hz), in mode order 1–4.
    public var toneFrequencies: [Double]
    /// Words/phrases biasing dictation recognition (names, jargon) via
    /// AnalysisContext.contextualStrings. Cheap, applied per-session.
    /// `vocabulary` is the curated built-in list (from the defaults file);
    /// `extraVocabulary` is the user's own additions. Two keys instead of
    /// merge magic: overriding either is plain per-key precedence.
    public var vocabulary: [String]
    public var extraVocabulary: [String]

    /// What consumers use: built-in plus user words, deduped in order.
    public var effectiveVocabulary: [String] {
        var seen = Set<String>()
        return (vocabulary + extraVocabulary).filter { seen.insert($0).inserted }
    }
    /// "mode1"…"mode4" (white per green mode), "modeChange" (green),
    /// "fxChange" (orange), "triggerDown"/"triggerUp" (handle).
    public var mappings: [String: TingAction]
    /// Post-recognition corrections applied to finalized transcript
    /// segments (word-boundary, case-sensitive). The escape hatch for
    /// words the recognizer's lexicon simply refuses to produce.
    public var replacements: [String: String]
    /// Post-dictation LLM rewrite pass.
    public var rewrite: RewriteConfig
    /// Per-app dictation profiles keyed by bundle id (`[apps."…"]`).
    public var apps: [String: AppProfile]
    /// Ordered fallback transcription apps (`[[fallback]]`).
    public var fallback: [AppProfile]
    public var routing: RoutingConfig

    /// The defaults document is the single source of truth: `default` is
    /// its parse (the bare-struct fallback below can only be reached if
    /// the embedded template is broken, which CI rejects).
    public static let `default` = (try? TingConfig.parse(toml: ConfigStore.defaultTOML))
        ?? TingConfig(toneFrequencies: [17500, 18000, 18500, 19000],
                      vocabulary: [], mappings: [:])

    init(toneFrequencies: [Double], vocabulary: [String],
         mappings: [String: TingAction], replacements: [String: String] = [:],
         rewrite: RewriteConfig = RewriteConfig(),
         apps: [String: AppProfile] = [:], fallback: [AppProfile] = [],
         routing: RoutingConfig = RoutingConfig()) {
        self.toneFrequencies = toneFrequencies
        self.vocabulary = vocabulary
        self.extraVocabulary = []
        self.mappings = mappings
        self.replacements = replacements
        self.rewrite = rewrite
        self.apps = apps
        self.fallback = fallback
        self.routing = routing
    }

    private enum CodingKeys: String, CodingKey {
        case toneFrequencies, vocabulary, extraVocabulary, mappings, replacements, rewrite,
             apps, fallback, routing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toneFrequencies = try container.decodeIfPresent([Double].self, forKey: .toneFrequencies)
            ?? [17500, 18000, 18500, 19000]
        vocabulary = try container.decodeIfPresent([String].self, forKey: .vocabulary) ?? []
        extraVocabulary = try container.decodeIfPresent([String].self, forKey: .extraVocabulary) ?? []
        mappings = try container.decodeIfPresent([String: TingAction].self, forKey: .mappings) ?? [:]
        replacements = try container.decodeIfPresent([String: String].self, forKey: .replacements) ?? [:]
        rewrite = try container.decodeIfPresent(RewriteConfig.self, forKey: .rewrite) ?? RewriteConfig()
        apps = try container.decodeIfPresent([String: AppProfile].self, forKey: .apps) ?? [:]
        fallback = try container.decodeIfPresent([AppProfile].self, forKey: .fallback) ?? []
        routing = try container.decodeIfPresent(RoutingConfig.self, forKey: .routing) ?? RoutingConfig()
    }

    /// Word-boundary, case-sensitive corrections for finalized transcript
    /// text. Longest keys win first so overlapping rules compose sanely.
    public static func applyReplacements(_ text: String, _ map: [String: String]) -> String {
        guard !map.isEmpty else { return text }
        var result = text
        for (key, value) in map.sorted(by: { $0.key.count > $1.key.count }) {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: key) + "\\b"
            result = result.replacingOccurrences(of: pattern, with: value,
                                                 options: .regularExpression)
        }
        return result
    }

    /// Parse literate TOML (exposed for tests).
    public static func parse(toml: String) throws -> TingConfig {
        try TOMLDecoder().decode(TingConfig.self, from: toml)
    }

    /// Layered parse: the user document is applied over the defaults with
    /// plain per-key precedence — a key the user writes wins wholesale
    /// (lists and inline tables included); a key they don't comes from
    /// defaults. Section tables ([rewrite], [mappings], [replacements])
    /// merge per contained key so overriding one mapping keeps the rest.
    public static func parse(defaults: String, user: String) throws -> TingConfig {
        let base = try TOMLTable(string: defaults)
        let overlay = try TOMLTable(string: user)
        return try TOMLDecoder().decode(TingConfig.self, from: merged(base: base, overlay: overlay))
    }

    private static func merged(base: TOMLTable, overlay: TOMLTable) -> TOMLTable {
        for key in overlay.keys {
            if let baseTable = base[key]?.table, let overTable = overlay[key]?.table,
               !baseTable.inline, !overTable.inline {
                base[key] = merged(base: baseTable, overlay: overTable)
            } else {
                base[key] = overlay[key]
            }
        }
        return base
    }

    public func action(forKey key: String) -> TingAction? {
        mappings[key]
    }

    public func action(for event: TingEvent) -> TingAction? {
        guard let key = event.mappingKey else { return nil }
        if let action = action(forKey: key) { return action }
        // "white" is a catch-all for white presses in any green mode, used
        // when the specific modeN key is unmapped.
        if case .whitePress = event { return action(forKey: "white") }
        return nil
    }
}

/// Menu-driven state that must NOT live in the user's hand-written TOML
/// (programmatic writes would destroy their comments): the pinned audio
/// input device. nil = automatic beacon discovery.
enum PinnedInput {
    private static let key = "audioInputDeviceUID"

    static var uid: String? {
        get { Prefs.suite.string(forKey: key) }
        set {
            if let newValue {
                Prefs.suite.set(newValue, forKey: key)
            } else {
                Prefs.suite.removeObject(forKey: key)
            }
        }
    }
}

/// Owns the on-disk config at ~/Library/Application Support/tingle/config.toml:
/// creates it with a literate default if missing, and live-reloads it on
/// change via a DispatchSource file watch (handles atomic saves too). The
/// file is user-authored only — tingle never writes to it after creation.
public final class ConfigStore {
    static let directoryURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("tingle", isDirectory: true)
    public static let configURL = directoryURL.appendingPathComponent("config.toml")
    public static let defaultConfigURL = directoryURL.appendingPathComponent("default-config.toml")

    /// The defaults document: single source of truth for every default,
    /// mirrored to default-config.toml on every launch so it is always
    /// current, browsable, and copy-from-able. Humans edit config.toml.
    public static let defaultTOML = """
    # tinker defaults - REWRITTEN BY TINKER ON EVERY LAUNCH; edits here are
    # lost. This file is the documentation: browse it, then copy any key
    # into config.toml (same folder) and change it there. Keys in
    # config.toml win; sections like [mappings] merge per key.
    #
    # -- The device ------------------------------------------------------------
    # Squeeze the ting's handle to dictate; release to finish.
    #   handle        -> "triggerDown" / "triggerUp"
    #   green button  -> "modeChange"   (also cycles the mode LED)
    #   orange button -> "fxChange"
    #   white button  -> "mode1".."mode4"  (which one depends on the mode LED)
    # Green and orange only register while the handle is released.
    #
    # -- Actions ------------------------------------------------------------
    #   { type = "dictate" }                     live transcription into the
    #                                            focused app (macOS 26+; only
    #                                            valid on triggerDown)
    #   { type = "eraseDictation" }              erase the last dictated take;
    #                                            press again for earlier takes
    #   { type = "send" }                        submit with the frontmost app's
    #                                            send shortcut (see [routing])
    #   { type = "keystroke", key = "return", modifiers = ["cmd"] }
    #   { type = "keyHold",   key = "f5" }       held until handle release
    #   { type = "shell",     command = "..." }  run with /bin/zsh -lc
    #
    # Keys: a-z, 0-9, f1-f20, return, escape, space, tab, delete,
    # forwarddelete, home, end, pageup, pagedown, arrows, and punctuation
    # by name (minus, equal, leftbracket, rightbracket, backslash,
    # semicolon, quote, comma, period, slash, grave).
    # Modifiers: "cmd", "shift", "opt", "ctrl".

    # Words and phrases that bias dictation recognition - names, jargon,
    # anything it keeps mishearing. Applied per-session, no training step.
    # Effective in the hundreds of entries (a giant dump dilutes the bias);
    # curate ruthlessly and add whatever it mangles for you.
    vocabulary = [
      "Claude", "Claude Code", "Codex", "tingle", "TOML",
      "JSON", "YAML", "GitHub", "git", "rebase",
      "repo", "monorepo", "changelog", "diff", "regex",
      "grep", "bash", "zsh", "shell", "sudo",
      "chmod", "ssh", "localhost", "DNS", "API",
      "CLI", "SDK", "IDE", "CI", "linter",
      "TypeScript", "JavaScript", "Python", "Swift", "SwiftPM",
      "Rust", "Xcode", "VS Code", "Cursor", "tmux",
      "Docker", "Kubernetes", "kubectl", "Postgres", "SQL",
      "SQLite", "Redis", "npm", "pip", "uv",
      "async", "await", "enum", "struct", "mutex",
      "goroutine", "lambda", "callback", "closure", "refactor",
      "backtrace", "stack trace", "segfault", "nil", "null",
      "boolean", "int", "float", "tuple", "dict",
      "hashmap", "iterator", "recursion", "memoize", "O of N",
      "big O", "endpoint", "webhook", "OAuth", "JWT",
      "TLS", "HTTPS", "gRPC", "protobuf", "WebSocket",
      "frontend", "backend", "middleware", "microservice", "Kafka",
      "cron", "daemon", "systemd", "launchd", "Homebrew",
      "cask", "notarize", "codesign", "entitlement", "TCC",
      "Tutor Intelligence", "teleop", "end effector", "gripper", "servo",
      "actuator", "encoder", "IMU", "lidar", "URDF",
      "ROS", "PLC", "kinematics", "inverse kinematics", "trajectory",
      "waypoint", "pick and place", "palletize", "conveyor", "workcell",
      "PCB", "firmware", "MicroPython", "RP2350", "UART",
      "GPIO", "I2C", "SPI", "ADC", "PWM",
      "oscilloscope", "solder", "Teenage Engineering", "Goertzel", "ultrasonic",
      "beacon", "chirp", "Cubilux", "line-in", "AAA battery",
      "power cycle",
      "subagent", "agentic", "LLM", "GPT", "Anthropic",
      "OpenAI", "Gemini", "prompt", "system prompt", "context window",
      "token", "tokenizer", "inference", "fine-tune", "RAG",
      "embedding", "vector database", "hallucination", "eval", "benchmark",
      "MCP", "tool call", "orchestration", "worktree", "sandbox",
      "headless", "transcript", "session", "hook", "slash command",
      "chain of thought",
      "depalletizing", "palletizing", "singulation", "kitting",
      "bin picking", "pick point", "cycle time", "throughput",
      "uptime", "downtime", "end-of-arm tooling", "EOAT",
      "suction cup", "vacuum gripper", "force-torque sensor", "tool center point",
      "flange", "wrist joint", "seventh axis", "gantry",
      "cobot", "stepper motor", "harmonic drive", "swerve drive",
      "infeed", "outfeed", "tote", "SKU",
      "carton", "slip sheet", "pallet jack", "light curtain",
      "area scanner", "e-stop", "interlock", "lockout tagout",
      "teach pendant", "homing", "joint limits", "joint space",
      "Cartesian", "quaternion", "rotation matrix", "kinematic chain",
      "forward kinematics", "singularity", "reachability", "motion planning",
      "collision checking", "payload", "calibration", "hand-eye calibration",
      "extrinsics", "intrinsics", "fiducial", "AprilTag",
      "ArUco", "point cloud", "depth camera", "UWB",
      "pose estimation", "bounding box", "segmentation", "YOLO",
      "ONNX", "TensorRT", "PyTorch", "quantization",
      "teleoperation", "provisioning", "commissioning", "site survey",
      "bootloader", "watchdog", "over-the-air update", "CAN bus",
      "CANopen", "Modbus", "EtherCAT", "RS-485",
      "HMI", "VFD", "PoE", "WireGuard",
      "WebRTC", "RTSP", "kustomize", "Terraform",
      "Dockerfile", "Grafana", "Prometheus", "ClickHouse",
      "alembic", "SQLAlchemy", "pytest", "mypy",
      "ruff",
      "Tutor",
      "README", "semver",
      "config",
    ]

    # Your words, concatenated onto the built-in vocabulary above. Add
    # here (in config.toml) so built-in list updates still reach you;
    # override `vocabulary` itself only to discard the built-ins.
    extraVocabulary = []

    # Corrections applied to finalized dictation text (word-boundary,
    # case-sensitive) - for words the recognizer refuses to spell right
    # no matter how much vocabulary biasing it gets.
    [replacements]
    "Tamil" = "TOML"
    "clawed" = "Claude"
    "Clawed" = "Claude"

    # After each take, an on-device language model (Apple Intelligence,
    # macOS 26+) can lightly clean the text in place: the take types
    # live as usual, then the polish lands a second later through the
    # same typing mechanics. Sending, erasing, a new squeeze, or
    # switching apps cancels a pending polish. Every switch below is a
    # fixed, tested instruction; customInstructions is freeform and is
    # applied last. Filler removal works even without Apple Intelligence.
    [rewrite]
    enabled = true
    removeFillers = true        # delete um/uh/er and the comma debris they leave
    fixPunctuation = true       # sentence boundaries, capitalization, run-ons
    fixGrammar = false          # light repair only; off because the model sometimes over-normalizes
    correctVocabulary = true    # let the model fix near-miss transcriptions of your vocabulary terms
    technicalFormatting = true  # "dash dash force" -> "--force", "foo dot py" -> "foo.py"
    customInstructions = ""

    [mappings]
    # Squeeze to dictate into whatever app is focused.
    triggerDown = { type = "dictate" }

    # White (any green mode): send it - the frontmost app's submit shortcut
    # ([apps."…"] send, else [routing] send). After MacWhisper/Handy finish,
    # it waits for the transcript to land before pressing. "white" is a
    # catch-all; map mode1..mode4 for per-mode actions instead.
    white = { type = "send" }

    # Green: scrap that take (press again for the take before it). Green
    # also cycles the ting's own mode LED - harmless, white sends in every
    # mode.
    modeChange = { type = "eraseDictation" }

    # Orange: unmapped. It cycles the ting's voice preset on the device
    # (all four are dry after Flash EP). Example - summon your agent:
    # fxChange = { type = "shell", command = '''
    # for app in "Claude" "Codex" "Cursor" "iTerm2" "Terminal"; do
    #   if osascript -e 'application "'"$app"'" is running' 2>/dev/null | grep -q true; then
    #     osascript -e 'tell application "'"$app"'" to activate'; exit 0
    #   fi
    # done
    # ''' }

    # -- Per-app voice routing (tinker) ----------------------------------------
    # On squeeze, tinker looks at the frontmost app:
    #   1. [apps."<bundle id>"]  -> drive THAT app's own dictation shortcut
    #   2. [[fallback]]          -> first entry whose app is running
    #   3. builtin               -> [mappings] triggerDown / triggerUp above
    # `dictation` describes the app's shortcut: mode "toggle" presses it on
    # squeeze and again on release; mode "hold" holds it for the whole
    # squeeze. Explicit triggerDown/triggerUp actions override the derived
    # ones. Dotted bundle ids must be quoted. [apps] tables merge per app
    # with these defaults; a [[fallback]] list in config.toml REPLACES this
    # whole list. Find a bundle id with:  osascript -e 'id of app "Codex"'
    [routing]
    enabled = true
    switchDefaultInput = false   # make the ting's adapter the system input while held
    showWaveform = true
    # What the orange button presses to submit, unless the frontmost app's
    # profile has its own `send`. Return submits a chat prompt or a web
    # form field; apps that treat Return as a newline want cmd+Return.
    send = { key = "return" }
    sendSettleSeconds = 2.5      # max wait for a fallback app's transcript to start arriving

    [apps."com.anthropic.claudefordesktop"]
    name = "Claude"
    dictation = { mode = "toggle", key = "d", modifiers = ["cmd"] }
    send = { key = "return" }

    [apps."com.openai.codex"]
    name = "Codex"
    # Codex's dictation key is set in Codex settings; bind its "press to
    # dictate" key to F18 there and keep this in sync.
    dictation = { mode = "hold", key = "f18" }
    send = { key = "return" }

    # Apps where Return inserts a newline and cmd+Return submits. These have
    # no dictation of their own, so a squeeze there uses the fallback list;
    # only `send` matters.
    [apps."com.apple.mail"]
    name = "Mail"
    send = { key = "d", modifiers = ["cmd", "shift"] }

    [apps."com.linear"]
    name = "Linear"
    send = { key = "return", modifiers = ["cmd"] }

    [[fallback]]
    name = "MacWhisper"
    bundleId = "com.goodsnooze.MacWhisper"
    # MacWhisper > Settings > Dictation: toggle mode, shortcut Control-Z.
    dictation = { mode = "toggle", key = "z", modifiers = ["ctrl"] }

    [[fallback]]
    name = "Handy"
    bundleId = "com.pais.handy"
    triggerDown = { type = "shell", command = "handy --toggle-transcription" }
    triggerUp   = { type = "shell", command = "handy --toggle-transcription" }
    """

    /// The starter user config: near-empty on purpose. The defaults doc
    /// carries the documentation; this file carries only what the user
    /// changes.
    public static let userTemplateTOML = """
    # tinker configuration - edit and save: tinker reloads it live.
    #
    # Every available key, documented, lives in default-config.toml next
    # to this file (rewritten by the app on every launch, so it is always
    # current). Copy anything you want to change into THIS file: keys
    # here win, and sections like [mappings] merge per key, so you only
    # need the lines you actually change.

    # Words the recognizer keeps mangling, added on top of the built-in
    # vocabulary list (see default-config.toml).
    extraVocabulary = []

    # Per-app routing lives in [apps."<bundle id>"] and [[fallback]]
    # tables - see default-config.toml for the shipped Claude, Codex,
    # MacWhisper and Handy entries and copy the ones you change here.
    """

    private(set) var config: TingConfig = .default

    private var observers: [() -> Void] = []
    private var watchSource: DispatchSourceFileSystemObject?
    private let log = Logger(subsystem: Log.subsystem, category: "config")

    init() {
        writeDefaultsMirror()
        ensureConfigFileExists()
        load()
        startWatching()
    }

    /// Register a callback fired (on the main queue) whenever the config reloads.
    func addObserver(_ block: @escaping () -> Void) {
        observers.append(block)
    }

    private func notifyObservers() {
        observers.forEach { $0() }
    }

    /// default-config.toml is a mirror of the embedded defaults, refreshed
    /// on every launch so it always documents the running version. The app
    /// never reads it back — a mangled mirror cannot break anything.
    private func writeDefaultsMirror() {
        do {
            try FileManager.default.createDirectory(
                at: Self.directoryURL, withIntermediateDirectories: true)
            if (try? String(contentsOf: Self.defaultConfigURL, encoding: .utf8)) != Self.defaultTOML {
                try Self.defaultTOML.write(to: Self.defaultConfigURL, atomically: true, encoding: .utf8)
                log.info("defaults mirror refreshed at \(Self.defaultConfigURL.path, privacy: .public)")
            }
        } catch {
            log.error("failed to write defaults mirror: \(String(describing: error))")
        }
    }

    private func ensureConfigFileExists() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: Self.configURL.path) {
                try Self.userTemplateTOML.write(to: Self.configURL, atomically: true, encoding: .utf8)
                log.info("created starter config at \(Self.configURL.path, privacy: .public)")
            }
        } catch {
            log.error("failed to create starter config: \(String(describing: error))")
        }
    }

    private func load() {
        do {
            let text = try String(contentsOf: Self.configURL, encoding: .utf8)
            config = try TingConfig.parse(defaults: Self.defaultTOML, user: text)
            log.info("config loaded (user overlay on defaults)")
        } catch {
            log.error("failed to load config (keeping previous): \(String(describing: error))")
        }
    }

    private func startWatching() {
        stopWatching()

        let fd = open(Self.configURL.path, O_EVTONLY)
        guard fd >= 0 else {
            log.error("cannot open config file for watching")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let source = self.watchSource else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Atomic save (or deletion): re-open the path after a beat.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self else { return }
                    self.ensureConfigFileExists()
                    self.load()
                    self.startWatching()   // re-arm on the new inode
                    self.notifyObservers()
                }
            } else {
                self.load()
                self.notifyObservers()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        watchSource = source
    }

    private func stopWatching() {
        watchSource?.cancel()
        watchSource = nil
    }

    deinit {
        stopWatching()
    }
}
