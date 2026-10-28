import AppKit
import SwiftUI

/// The Settings window (tinker): apps with their own dictation, the
/// fallback transcription apps, and the routing switches. Every change is
/// saved and re-layered into the live config immediately.
/// Setup-time state and actions the Device tab shows, fed by
/// StatusItemController (which owns the coordinator, flasher and
/// permissions). Keeps the menu bar menu to day-to-day items.
final class DeviceModel: ObservableObject {
    @Published var statusText = ""
    @Published var batteryText: String?
    @Published var diskMounted = false
    @Published var isFlashing = false
    @Published var flashStatus: String?
    @Published var flashTitle = "Flash EP…"
    @Published var firmwareText = ""
    @Published var firmwareUpgradeAvailable = false
    @Published var inputDevices: [(name: String, uid: String)] = []
    @Published var pinnedUID: String?
    @Published var micGranted = true
    @Published var accessibilityGranted = true
    @Published var version = ""

    var onFlash: () -> Void = {}
    var onRestore: () -> Void = {}
    var onUpgradeFirmware: () -> Void = {}
    var onSelectInput: (String?) -> Void = { _ in }
    var onCopyDiagnostics: () -> Void = {}
    var onSimulate: () -> Void = {}
    var onOpenConfig: () -> Void = {}
    var onOpenDefaults: () -> Void = {}
    var onFixMic: () -> Void = {}
    var onFixAccessibility: () -> Void = {}
}

final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel
    private let device: DeviceModel
    private var pendingTab: SettingsTab?

    init(configStore: ConfigStore, device: DeviceModel) {
        model = SettingsModel(configStore: configStore)
        self.device = device
    }

    func show(tab: SettingsTab? = nil) {
        if let tab { model.selectedTab = tab }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model, device: device))
            let w = NSWindow(contentViewController: hosting)
            w.title = "tinker Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 960, height: 640))
            w.minSize = NSSize(width: 840, height: 540)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        model.reloadFromDisk()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsTab: Hashable { case apps, fallback, general, device }

final class SettingsModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet { scheduleSave() }
    }
    @Published var selectedApp: String?
    @Published var selectedFallback: String?
    @Published var selectedTab: SettingsTab = .apps

    private let store = SettingsStore()
    private let configStore: ConfigStore
    private var saveWork: DispatchWorkItem?
    private var loading = false

    init(configStore: ConfigStore) {
        self.configStore = configStore
        settings = store.current(seedFrom: configStore.config)
        selectedApp = settings.apps.first?.id
        selectedFallback = settings.fallbacks.first?.id
    }

    func reloadFromDisk() {
        loading = true
        settings = store.current(seedFrom: configStore.config)
        loading = false
    }

    private func scheduleSave() {
        guard !loading else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.store.save(self.settings)
            self.configStore.reload()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let info = SettingsStore.appInfo(at: url) else { return }
        if let existing = settings.apps.firstIndex(where: { $0.bundleId == info.bundleId }) {
            settings.apps[existing].enabled = true
            selectedApp = info.bundleId
            return
        }
        settings.apps.append(AppSettings.AppEntry(bundleId: info.bundleId, name: info.name))
        selectedApp = info.bundleId
    }

    func addFallback() {
        let panel = NSOpenPanel()
        panel.title = "Choose a transcription application"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let info = SettingsStore.appInfo(at: url) else { return }
        if let existing = settings.fallbacks.firstIndex(where: { $0.bundleId == info.bundleId }) {
            settings.fallbacks[existing].enabled = true
            selectedFallback = info.bundleId
            return
        }
        settings.fallbacks.append(AppSettings.FallbackEntry(bundleId: info.bundleId, name: info.name))
        selectedFallback = info.bundleId
    }

    func removeSelectedApp() {
        guard let id = selectedApp else { return }
        settings.apps.removeAll { $0.id == id }
        selectedApp = settings.apps.first?.id
    }

    func removeSelectedFallback() {
        guard let id = selectedFallback else { return }
        settings.fallbacks.removeAll { $0.id == id }
        selectedFallback = settings.fallbacks.first?.id
    }

    func moveFallback(_ id: String, by delta: Int) {
        guard let i = settings.fallbacks.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard settings.fallbacks.indices.contains(j) else { return }
        settings.fallbacks.swapAt(i, j)
    }

    func resetToPresets() {
        settings = .presets
        selectedApp = settings.apps.first?.id
        selectedFallback = settings.fallbacks.first?.id
    }
}

// MARK: - Views

private enum SettingsSpacing {
    static let window: CGFloat = 24
    static let pane: CGFloat = 20
    static let editor: CGFloat = 8
    static let controls: CGFloat = 14
    static let row: CGFloat = 4
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var device: DeviceModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            AppsTab(model: model)
                .tabItem { Label("Apps", systemImage: "app.badge") }
                .tag(SettingsTab.apps)
            FallbacksTab(model: model)
                .tabItem { Label("Fallback", systemImage: "waveform") }
                .tag(SettingsTab.fallback)
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            DeviceTab(device: device)
                .tabItem { Label("Device", systemImage: "mic") }
                .tag(SettingsTab.device)
        }
        .padding(SettingsSpacing.window)
    }
}

/// Setup and maintenance for the ting itself: everything that used to
/// crowd the menu bar menu but is only needed once per Mac.
struct DeviceTab: View {
    @ObservedObject var device: DeviceModel

    var body: some View {
        Form {
            Section("ting") {
                LabeledContent("Status", value: device.statusText)
                if let battery = device.batteryText {
                    LabeledContent("Battery", value: battery)
                }
                if !device.micGranted {
                    HStack {
                        Text("⚠️ Microphone access not granted")
                        Spacer()
                        Button("Fix…") { device.onFixMic() }
                    }
                }
                if !device.accessibilityGranted {
                    HStack {
                        Text("⚠️ Accessibility access not granted")
                        Spacer()
                        Button("Fix…") { device.onFixAccessibility() }
                    }
                }
            }
            Section("Audio input") {
                Picker("Listen on", selection: Binding(
                    get: { device.pinnedUID ?? "" },
                    set: { device.onSelectInput($0.isEmpty ? nil : $0) })) {
                    Text("Automatic (find the ting's heartbeat)").tag("")
                    ForEach(device.inputDevices, id: \.uid) { d in Text(d.name).tag(d.uid) }
                }
                Text("The USB audio adapter the ting's 3.5mm cable is plugged into. Automatic works when the adapter's name contains \"line in\"; otherwise pick it here once.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Setup (dock the ting over USB-C)") {
                HStack {
                    Button(device.flashTitle) { device.onFlash() }
                        .disabled(!device.diskMounted || device.isFlashing)
                    Text(device.diskMounted ? "TINGDISK is mounted." : "Plug the ting into the Mac over USB-C to enable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Upgrade ting firmware…") { device.onUpgradeFirmware() }
                        .disabled(!device.firmwareUpgradeAvailable || device.isFlashing)
                    Text(device.firmwareText).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Restore stock") { device.onRestore() }
                        .disabled(!device.diskMounted || device.isFlashing)
                    Text("Removes the event engine and tones from the ting's disk.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let status = device.flashStatus {
                    Text(status).font(.caption)
                }
                Text("Flash EP installs tinker's event engine and inaudible signal tones on the ting (one-time; a new ting gets the firmware upgrade first). A ting set up on another Mac is recognised automatically.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Tools") {
                HStack {
                    Button("Simulate squeeze (2 s)") { device.onSimulate() }
                    Button("Copy diagnostics") { device.onCopyDiagnostics() }
                    Button("Open config.toml") { device.onOpenConfig() }
                    Button("View default config") { device.onOpenDefaults() }
                }
                Text("Simulate squeeze routes exactly like a real one for the app you came from. These are also in the menu bar menu while holding ⌥.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LabeledContent("Version", value: device.version)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppIcon: View {
    let bundleId: String
    var body: some View {
        if let image = SettingsStore.icon(forBundleId: bundleId) {
            Image(nsImage: image).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.dashed").frame(width: 20, height: 20)
        }
    }
}

struct AppsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: SettingsSpacing.controls) {
                Text("When one of these is in front, squeezing drives its own dictation shortcut. The white button presses its send key.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                List(selection: $model.selectedApp) {
                    ForEach($model.settings.apps) { $app in
                        HStack {
                            Toggle("", isOn: $app.enabled).labelsHidden()
                            AppIcon(bundleId: app.bundleId)
                            VStack(alignment: .leading) {
                                Text(app.name)
                                Text(summary(for: app)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, SettingsSpacing.row)
                        .tag(app.id)
                    }
                }
                HStack {
                    Button("Add app…") { model.addApp() }
                    Button("Remove") { model.removeSelectedApp() }.disabled(model.selectedApp == nil)
                }
            }
            .padding(SettingsSpacing.pane)
            .frame(minWidth: 280)

            Group {
                if let index = model.settings.apps.firstIndex(where: { $0.id == model.selectedApp }) {
                    AppEditor(app: $model.settings.apps[index])
                } else {
                    Text("Select an app").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(SettingsSpacing.editor)
            .frame(minWidth: 400)
        }
    }

    private func summary(for app: AppSettings.AppEntry) -> String {
        var parts: [String] = []
        if app.mode != .none, !app.key.isEmpty {
            parts.append("\(KeyCodes.symbol(key: app.key, modifiers: app.modifiers)) (\(app.mode.rawValue))")
        } else {
            parts.append("uses fallback")
        }
        if !app.sendKey.isEmpty {
            parts.append("send \(KeyCodes.symbol(key: app.sendKey, modifiers: app.sendModifiers))")
        }
        return parts.joined(separator: " · ")
    }
}

struct AppEditor: View {
    @Binding var app: AppSettings.AppEntry

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $app.name)
                LabeledContent("Bundle id") {
                    Text(app.bundleId).textSelection(.enabled).font(.caption.monospaced())
                }
            }
            Section("Dictation shortcut") {
                Picker("Mode", selection: $app.mode) {
                    ForEach(AppSettings.DictationMode.allCases) { Text($0.label).tag($0) }
                }
                if app.mode != .none {
                    ChordEditor(key: $app.key, modifiers: $app.modifiers)
                    Text("Set the same shortcut inside \(app.name). Toggle: pressed once on squeeze and once on release. Hold: held down for the whole squeeze.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("Send (white button)") {
                ChordEditor(key: $app.sendKey, modifiers: $app.sendModifiers)
                Text("Return submits a chat box or form field; apps that make Return a newline usually submit with ⌘Return.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

struct FallbacksTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: SettingsSpacing.controls) {
                Text("For apps without a profile, the first enabled app here that is running takes the squeeze. When none is running, tinker's built-in on-device dictation types for you.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                List(selection: $model.selectedFallback) {
                    ForEach($model.settings.fallbacks) { $fb in
                        HStack {
                            Toggle("", isOn: $fb.enabled).labelsHidden()
                            AppIcon(bundleId: fb.bundleId)
                            VStack(alignment: .leading) {
                                Text(fb.name)
                                Text(summary(for: fb)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if isRunning(fb.bundleId) {
                                Text("running").font(.caption).foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, SettingsSpacing.row)
                        .tag(fb.id)
                    }
                }
                HStack {
                    Button("Add app…") { model.addFallback() }
                    Button("Remove") { model.removeSelectedFallback() }.disabled(model.selectedFallback == nil)
                    Spacer()
                    Button { if let id = model.selectedFallback { model.moveFallback(id, by: -1) } } label: { Image(systemName: "chevron.up") }
                    Button { if let id = model.selectedFallback { model.moveFallback(id, by: 1) } } label: { Image(systemName: "chevron.down") }
                }
            }
            .padding(SettingsSpacing.pane)
            .frame(minWidth: 280)

            Group {
                if let index = model.settings.fallbacks.firstIndex(where: { $0.id == model.selectedFallback }) {
                    FallbackEditor(fallback: $model.settings.fallbacks[index])
                } else {
                    Text("Select a fallback app").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(SettingsSpacing.editor)
            .frame(minWidth: 400)
        }
    }

    private func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    private func summary(for fb: AppSettings.FallbackEntry) -> String {
        switch fb.kind {
        case .shortcut:
            return fb.key.isEmpty ? "no shortcut set"
                : "\(KeyCodes.symbol(key: fb.key, modifiers: fb.modifiers)) (\(fb.mode == .none ? "toggle" : fb.mode.rawValue))"
        case .shell:
            return fb.shellDown.isEmpty ? "no command set" : fb.shellDown
        }
    }
}

struct FallbackEditor: View {
    @Binding var fallback: AppSettings.FallbackEntry

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $fallback.name)
                LabeledContent("Bundle id") {
                    Text(fallback.bundleId).textSelection(.enabled).font(.caption.monospaced())
                }
                Toggle("Only while it is running", isOn: $fallback.requireRunning)
            }
            Section("How to start it") {
                Picker("Trigger", selection: $fallback.kind) {
                    ForEach(AppSettings.FallbackKind.allCases) { Text($0.label).tag($0) }
                }
                switch fallback.kind {
                case .shortcut:
                    Picker("Mode", selection: $fallback.mode) {
                        Text("Toggle").tag(AppSettings.DictationMode.toggle)
                        Text("Hold").tag(AppSettings.DictationMode.hold)
                    }
                    ChordEditor(key: $fallback.key, modifiers: $fallback.modifiers)
                    Text("Match this to the dictation shortcut configured in \(fallback.name).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .shell:
                    TextField("On squeeze", text: $fallback.shellDown)
                    TextField("On release", text: $fallback.shellUp)
                    Text("Run with /bin/zsh -lc, e.g. handy --toggle-transcription.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("While the handle is held") {
                Toggle("Make the ting's audio adapter the system input", isOn: $model.settings.switchDefaultInput)
                Text("So Claude, Codex or MacWhisper record the ting's mic instead of the laptop's. Restored on release.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Show a live waveform in the menu bar", isOn: $model.settings.showWaveform)
            }
            Section("Send (white button) for apps without their own send key") {
                ChordEditor(key: $model.settings.sendKey, modifiers: $model.settings.sendModifiers)
                HStack {
                    Text("Wait up to")
                    TextField("", value: $model.settings.sendSettleSeconds, format: .number.precision(.fractionLength(1)))
                        .frame(width: 50)
                    Text("seconds for a fallback app's transcript to start arriving before sending")
                }
                .font(.callout)
            }
            Section {
                HStack {
                    Button("Open config.toml…") {
                        NSWorkspace.shared.open(ConfigStore.configURL)
                    }
                    Text("Vocabulary, replacements and the ting's button mappings live there.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button("Reset apps and fallbacks to the presets") { model.resetToPresets() }
            }
        }
        .formStyle(.grouped)
        .padding(SettingsSpacing.editor)
    }
}

/// Key popup plus modifier toggles. No key recorder on purpose: the keys
/// worth binding (F13–F20) usually are not on the keyboard at hand.
struct ChordEditor: View {
    @Binding var key: String
    @Binding var modifiers: [String]

    static let keyChoices: [String] = {
        var keys = (1...20).map { "f\($0)" }
        keys += ["return", "space", "tab", "escape", "delete", "forwarddelete",
                 "home", "end", "pageup", "pagedown", "up", "down", "left", "right"]
        keys += "abcdefghijklmnopqrstuvwxyz".map(String.init)
        keys += "0123456789".map(String.init)
        keys += ["minus", "equal", "leftbracket", "rightbracket", "backslash",
                 "semicolon", "quote", "comma", "period", "slash", "grave"]
        return keys
    }()

    private static let modifierChoices: [(name: String, label: String, help: String)] = [
        ("ctrl", "⌃", "Control"), ("opt", "⌥", "Option"), ("shift", "⇧", "Shift"), ("cmd", "⌘", "Command"), ("fn", "fn", "Function"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Key", selection: $key) {
                    Text("none").tag("")
                    ForEach(Self.keyChoices, id: \.self) { k in
                        Text(k.count == 1 ? k.uppercased() : (k.hasPrefix("f") && Int(k.dropFirst()) != nil ? k.uppercased() : k)).tag(k)
                    }
                }
                .frame(maxWidth: 220)
                Text(key.isEmpty ? "" : KeyCodes.symbol(key: key, modifiers: modifiers))
                    .font(.title3.monospaced())
            }
            HStack(spacing: 14) {
                ForEach(Self.modifierChoices, id: \.name) { choice in
                    Toggle(choice.label, isOn: Binding(
                        get: { modifiers.contains(choice.name) },
                        set: { on in
                            if on { if !modifiers.contains(choice.name) { modifiers.append(choice.name) } }
                            else { modifiers.removeAll { $0 == choice.name } }
                        }))
                    .toggleStyle(.checkbox)
                    .help(choice.help)
                }
                Spacer()
            }
        }
    }
}
