import AppKit
import os

/// Public entry point: the executable target is a one-liner calling this.
public enum TingleApp {
    /// Held for the process lifetime; the advisory lock it carries enforces
    /// the single-instance rule.
    private static var lockFD: Int32 = -1

    /// Only one tingle may run at a time (dev binary OR installed .app):
    /// two instances would double-type dictation and fight over the serial
    /// port. LaunchServices only dedupes Finder/`open` launches, so a
    /// directly-exec'd dev binary needs its own guard: an advisory flock on
    /// a well-known path, held for the process lifetime.
    private static func exitIfAlreadyRunning() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tingle", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("tingle.lock").path
        lockFD = open(path, O_CREAT | O_RDWR, 0o644)
        guard lockFD >= 0 else { return }  // can't lock -> don't block launch
        if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            Logger(subsystem: Log.subsystem, category: "app")
                .error("another tingle instance holds \(path, privacy: .public); exiting")
            exit(0)
        }
    }

    public static func main() {
        // Bundle self-test (used by CI on the assembled .app): verify the
        // device payload is loadable from this build's real resource layout,
        // print its size, and exit — regression guard for the Flash EP
        // crash where a CI-built app couldn't find its resource bundle.
        if ProcessInfo.processInfo.environment["TINGLE_PAYLOAD_CHECK"] != nil {
            do {
                let payload = try Flasher.devicePayload()
                print("payload ok: \(payload.count) bytes")
                exit(0)
            } catch {
                print("payload missing: \(error)")
                exit(1)
            }
        }
        exitIfAlreadyRunning()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}


enum Log {
    /// Kept as upstream's subsystem on purpose: it is only a log filter and
    /// changing it would touch every `log stream` predicate in the docs.
    static let subsystem = "com.tutorintelligence.tingle"
}

/// tinker's own identity (distinct from upstream tingle so macOS keeps
/// separate TCC rows and preferences for the two apps).
public enum AppIdentity {
    public static let bundleID = "com.noahread.tinker"
    public static let displayName = "tinker"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var configStore: ConfigStore!
    private var actionRunner: ActionRunner!
    private var coordinator: DetectionCoordinator!
    private var dictation: DictationController!
    private var statusItemController: StatusItemController!
    private let userInputMonitor = UserInputMonitor()
    private var permissions: PermissionsMonitor!
    /// tinker: the route the current squeeze drives (see RouteResolver).
    private var routeSession = RouteSession()
    private let inputSwitcher = DefaultInputSwitcher()

    private let log = Logger(subsystem: Log.subsystem, category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        configStore = ConfigStore()
        actionRunner = ActionRunner()
        coordinator = DetectionCoordinator(configStore: configStore)
        dictation = DictationController(
            configStore: configStore,
            coordinator: coordinator,
            actionRunner: actionRunner
        )

        wireTriggerHints(to: coordinator)
        coordinator.onEvent = { [weak self] event in
            guard let self else { return }
            self.handle(event: event)
        }

        // Wire the menu before starting so the initial state change is observed.
        permissions = PermissionsMonitor()
        statusItemController = StatusItemController(
            configStore: configStore, coordinator: coordinator, permissions: permissions)
        statusItemController.onSimulatedEvent = { [weak self] event in self?.handle(event: event) }
        userInputMonitor.onUserInput = { [weak self] in
            self?.dictation.contentMoved()
        }
        userInputMonitor.start()
        dictation.onRewriteActive = { [weak self] active in
            self?.statusItemController?.setRewriteActive(active)
        }
        dictation.onStatusChange = { [weak self] text in
            self?.statusItemController?.setDictationStatus(text)
        }
        coordinator.start()
        permissions.startMonitoring()
        // Surface any missing permission NOW, with the system dialogs that
        // deep-link to the right pane — never let the user discover it as a
        // squeeze that types nothing.
        permissions.promptForMissing()

        log.info("tingle started (config at \(ConfigStore.configURL.path, privacy: .public))")
    }

    /// Owns the belief about the handle: edges update it, state-bearing
    /// beacons reconcile it (synthesizing edges lost to decode errors or
    /// backend handovers such as USB plug/unplug). Semantics: piggyback
    /// the device's TRUE state; edges give responsiveness, beacons give
    /// eventual correctness within one heartbeat.
    private var reconciler = TriggerReconciler()
    /// Chatter filter: the trigger switch bounces (rapid down/up within a
    /// tick or two). A reversing edge within this window is mechanical
    /// noise, not a real press/release, and is dropped. Real squeezes last
    /// far longer than switch bounce.
    private var lastTriggerEdgeAt = Date.distantPast
    private let triggerChatterWindow: TimeInterval = 0.09

    func wireTriggerHints(to coordinator: DetectionCoordinator) {
        coordinator.onTriggerHint = { [weak self] held in
            guard let self else { return }
            switch self.reconciler.reconcile(beaconSaysHeld: held) {
            case .none:
                break
            case .synthesizeUp:
                self.log.warning("beacon says released but belief is held — synthesizing missed triggerUp")
                self.handle(event: .triggerUp)
            case .synthesizeDown:
                self.log.warning("beacon says held but belief is released — synthesizing missed triggerDown")
                self.handle(event: .triggerDown)
            }
        }
    }

    private func handle(event: TingEvent) {
        // Any real user gesture invalidates a pending dictation rewrite —
        // especially orange (send): text that may already be submitted
        // must never be edited afterward.
        switch event {
        case .beacon, .beaconHeld, .beaconSensed: break
        default: dictation.cancelPendingRewrite()
        }
        log.info("event: \(event.logDescription, privacy: .public)")

        if event == .triggerDown || event == .triggerUp {
            let now = Date()
            let down = event == .triggerDown
            let decision = TriggerRouting.decide(
                down: down, held: reconciler.held,
                msSinceLastEdge: now.timeIntervalSince(lastTriggerEdgeAt) * 1000,
                chatterMs: triggerChatterWindow * 1000
            )
            if decision.dropAsChatter {
                log.info("trigger chatter dropped (\(event.logDescription, privacy: .public))")
                return
            }
            _ = reconciler.apply(edgeDown: down)   // keep belief in sync for beacon healing
            lastTriggerEdgeAt = now

            // Lifecycle first, UNCONDITIONALLY: a release must always stop
            // dictation (both idempotent) so a session can never wedge past
            // the trigger being let go.
            if decision.releaseHeldKeys { actionRunner.releaseHeldKeys() }
            if decision.stopDictation { dictation.stopDictation() }
            if let held = decision.setHeld { statusItemController.setTriggerHeld(held) }

            if !down {
                // Close whatever route the squeeze opened — gated by the
                // session, not by fireMappedAction, so a desynced release
                // still sends the closing toggle exactly once.
                closeRoute()
                return
            }

            // Only a genuine press opens a route (dedup: a repeated edge
            // must never re-open a toggle).
            guard decision.fireMappedAction else { return }
            openRoute()
            return
        }

        guard let action = configStore.config.action(for: event) else {
            log.info("no action mapped for \(event.mappingKey ?? "unmappable event", privacy: .public)")
            return
        }

        // dictate only starts on triggerDown (handled above); ignore elsewhere.
        if action == .dictate {
            if event != .triggerDown {
                log.warning("\"dictate\" is only valid on the triggerDown mapping; ignoring on \(event.mappingKey ?? "?", privacy: .public)")
            }
            return
        }

        if action == .eraseDictation {
            dictation.eraseLastSession()
            return
        }

        // A typing action while dictation is live changes the text field
        // under the typer; freeze what's on screen first so corrections
        // can't backspace over it (the overwrite bug).
        switch action {
        case .keystroke, .keyHold:
            dictation.contentMoved()
        default:
            break
        }

        actionRunner.run(action)
    }

    // MARK: - Routing (tinker)

    private func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// Squeeze: pick the route for the frontmost app and fire its down action.
    private func openRoute() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let route = RouteResolver.resolve(
            frontmost: frontmost?.bundleIdentifier, frontmostName: frontmost?.localizedName,
            running: runningBundleIDs(), config: configStore.config)
        guard let down = routeSession.press(route) else {
            log.warning("route already active; ignoring duplicate press")
            return
        }
        log.info("route: \(route.name, privacy: .public) (\(String(describing: route.kind), privacy: .public)) → \(route.summary, privacy: .public)")
        statusItemController.setActiveRoute(route)
        LevelMeter.shared.arm()

        if route.usesBuiltinDictation {
            dictation.startDictation()
            return
        }

        guard actionRunner.ensureAccessibility() else {
            statusItemController.setDictationStatus("⚠️ Accessibility needed — open the tinker menu")
            return
        }
        // External app: no engine runs in serial mode, so hold one for the
        // meter (never on main — WarmCapture syncs onto the engine queue).
        let startMeter = { [self] in
            guard coordinator.runningAudioBackend == nil,
                  let uid = InputDeviceSelector.resolvedCaptureUID() else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                _ = WarmCapture.shared.holdForMetering(uid: uid)
            }
        }
        let fire = { [self] in
            switch down {
            case .keystroke, .keyHold: dictation.contentMoved()
            default: break
            }
            actionRunner.run(down)
        }
        if configStore.config.routing.switchDefaultInput, let uid = InputDeviceSelector.resolvedCaptureUID() {
            inputSwitcher.engage(uid: uid)
            // Give CoreAudio a beat to publish the new default before the
            // app opens its recorder, and let the device change settle
            // before the meter engine starts — a default-input switch
            // posts a configuration change that would discard it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: fire)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: startMeter)
        } else {
            fire()
            startMeter()
        }
    }

    /// Release: fire the remembered route's up action (once) and tidy up.
    private func closeRoute() {
        let route = routeSession.active
        let up = routeSession.release(running: runningBundleIDs())
        statusItemController.setActiveRoute(nil)
        // Built-in dictation owns its status line ("Inserted N words");
        // only clear the accessibility warning an external route may have set.
        if route?.usesBuiltinDictation != true { statusItemController.setDictationStatus(nil) }
        LevelMeter.shared.disarm()
        WarmCapture.shared.releaseMetering()
        inputSwitcher.restore()
        guard let route else { return }
        guard let up else {
            if route.up != nil {
                log.info("route \(route.name, privacy: .public): app gone; skipping up action")
            }
            return
        }
        let fire = { [self] in
            if case .keystroke = up { dictation.contentMoved() }
            actionRunner.run(up)
        }
        // A toggle must close in the app it opened in: if focus moved
        // mid-hold, bring that app back first.
        if route.kind == .app, let id = route.bundleId,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier != id,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            log.info("route \(route.name, privacy: .public): re-activating before closing toggle")
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: fire)
        } else {
            fire()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave a keyHold key stuck down or the input device switched
        // when quitting.
        actionRunner?.releaseHeldKeys()
        inputSwitcher.restore()
        coordinator?.stop()
    }
}
