import Foundation

/// Where a squeeze sends the voice. Pure data: AppDelegate executes the
/// actions, StatusItemController renders the name.
public struct Route: Equatable {
    public enum Kind: Equatable { case app, fallback, builtin }
    public var kind: Kind
    /// "Claude", "MacWhisper", "built-in".
    public var name: String
    public var bundleId: String?
    /// nil down = nothing to post (builtin with no mapping).
    public var down: TingAction?
    public var up: TingAction?
    /// "⌘D (toggle)", "F18 (hold)", "dictate", "shell".
    public var summary: String
    /// Fallback routes that only make sense while their app runs.
    public var requireRunning: Bool

    public init(kind: Kind, name: String, bundleId: String?, down: TingAction?, up: TingAction?,
                summary: String, requireRunning: Bool = false) {
        self.kind = kind
        self.name = name
        self.bundleId = bundleId
        self.down = down
        self.up = up
        self.summary = summary
        self.requireRunning = requireRunning
    }

    /// Built-in dictation needs DictationController rather than ActionRunner.
    public var usesBuiltinDictation: Bool { down == .dictate }
}

/// Pure decision: frontmost app + running apps + config -> Route.
public enum RouteResolver {
    public static let builtinName = "built-in"

    /// Expand a profile into the (down, up) action pair the handle fires.
    /// Explicit triggerDown/triggerUp override the `dictation` sugar per
    /// key. `up` may never be keyHold or dictate (both are press-only;
    /// the lifecycle invariant releases keys / stops dictation itself).
    public static func actions(for profile: AppProfile) -> (down: TingAction?, up: TingAction?) {
        var down: TingAction?
        var up: TingAction?
        if let d = profile.dictation {
            switch d.mode {
            case .toggle:
                down = .keystroke(key: d.key, modifiers: d.modifiers)
                up = .keystroke(key: d.key, modifiers: d.modifiers)
            case .hold:
                down = .keyHold(key: d.key, modifiers: d.modifiers)
                up = nil
            }
        }
        if let explicitDown = profile.triggerDown { down = explicitDown }
        if let explicitUp = profile.triggerUp { up = explicitUp }
        if let u = up {
            switch u {
            case .keyHold, .dictate: up = nil
            default: break
            }
        }
        return (down, up)
    }

    public static func summary(for profile: AppProfile, down: TingAction?) -> String {
        if profile.triggerDown == nil, let d = profile.dictation { return d.summary }
        switch down {
        case .keystroke(let key, let modifiers)?:
            return KeyCodes.symbol(key: key, modifiers: modifiers) + " (toggle)"
        case .keyHold(let key, let modifiers)?:
            return KeyCodes.symbol(key: key, modifiers: modifiers) + " (hold)"
        case .shell?: return "shell"
        case .dictate?: return "dictate"
        case .eraseDictation?: return "erase"
        case nil: return "nothing"
        }
    }

    /// The route a squeeze would take right now.
    public static func resolve(frontmost: String?, frontmostName: String? = nil,
                               running: Set<String>, config: TingConfig) -> Route {
        guard config.routing.enabled else { return builtin(config) }
        if let id = frontmost, let profile = config.apps[id] {
            let (down, up) = actions(for: profile)
            if down != nil {
                return Route(kind: .app, name: profile.name ?? frontmostName ?? id, bundleId: id,
                             down: down, up: up, summary: summary(for: profile, down: down))
            }
        }
        return fallback(running: running, config: config)
    }

    /// The fallback that applies when the frontmost app has no profile.
    public static func fallback(running: Set<String>, config: TingConfig) -> Route {
        guard config.routing.enabled else { return builtin(config) }
        for profile in config.fallback {
            guard let id = profile.bundleId else { continue }
            if profile.requireRunning && !running.contains(id) { continue }
            let (down, up) = actions(for: profile)
            guard down != nil else { continue }
            return Route(kind: .fallback, name: profile.name ?? id, bundleId: id,
                         down: down, up: up, summary: summary(for: profile, down: down),
                         requireRunning: profile.requireRunning)
        }
        return builtin(config)
    }

    public static func builtin(_ config: TingConfig) -> Route {
        let down = config.mappings["triggerDown"]
        var up = config.mappings["triggerUp"]
        if case .keyHold? = up { up = nil }
        if case .dictate? = up { up = nil }
        let summary: String
        switch down {
        case .dictate?, nil: summary = "dictate"
        case .keystroke(let key, let modifiers)?: summary = KeyCodes.symbol(key: key, modifiers: modifiers)
        case .keyHold(let key, let modifiers)?: summary = KeyCodes.symbol(key: key, modifiers: modifiers) + " (hold)"
        case .shell?: summary = "shell"
        case .eraseDictation?: summary = "erase"
        }
        return Route(kind: .builtin, name: builtinName, bundleId: nil, down: down, up: up, summary: summary)
    }

    /// "Claude → ⌘D (toggle)" / "built-in dictation".
    public static func describe(_ route: Route) -> String {
        if route.kind == .builtin { return "\(route.name) \(route.summary == "dictate" ? "dictation" : route.summary)" }
        return "\(route.name) → \(route.summary)"
    }
}

/// Remembers the route chosen at squeeze so the release closes the SAME
/// app's toggle even if focus moved mid-hold, and closes it exactly once.
public struct RouteSession: Equatable {
    public private(set) var active: Route?

    public init() {}

    /// Returns the down action to fire; nil (no-op) if a route is already
    /// active — a duplicate press must never re-open a toggle.
    public mutating func press(_ route: Route) -> TingAction? {
        guard active == nil else { return nil }
        active = route
        return route.down
    }

    /// Returns the up action to fire (exactly once per press). nil when no
    /// route is active or a requireRunning fallback app quit mid-hold —
    /// posting its hotkey would land in whatever is focused instead.
    public mutating func release(running: Set<String>) -> TingAction? {
        guard let route = active else { return nil }
        active = nil
        if route.requireRunning, let id = route.bundleId, !running.contains(id) { return nil }
        return route.up
    }
}
