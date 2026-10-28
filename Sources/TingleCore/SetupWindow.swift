import AppKit
import SwiftUI
import Combine

/// A reusable, non-modal home for setup. Permission actions stay owned by
/// PermissionsMonitor; this window only presents their current state.
final class SetupWindow: NSObject {
    private var window: NSWindow?

    func show(permissions: PermissionsMonitor, configureDevice: @escaping () -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let content = SetupView(permissions: permissions, configureDevice: configureDevice)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 590),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "tinker Setup"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SetupView: View {
    let permissions: PermissionsMonitor
    let configureDevice: () -> Void
    @State private var microphone = false
    @State private var accessibility = false
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 48)).foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Squeeze. Speak. Let go.").fixedSize(horizontal: false, vertical: true).font(.title2.weight(.semibold))
                    Text("Turn your ting into a push-to-talk controller.").fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            TabView {
                Form {
                    Section {
                        permissionRow("Microphone", detail: "Listen for your ting and use built-in dictation.",
                                      symbol: "mic", granted: microphone, action: permissions.fixMicrophone)
                        permissionRow("Accessibility", detail: "Control dictation shortcuts and insert your words.",
                                      symbol: "hand.raised", granted: accessibility, action: permissions.fixAccessibility)
                    } header: { Text("Allow access").fixedSize(horizontal: false, vertical: true) } footer: {
                        Text("Permissions update here when you return from System Settings.").fixedSize(horizontal: false, vertical: true)
                    }
                    Section("Try it") {
                        Label("Click a text field in the app you want to use.", systemImage: "cursorarrow")
                        Label("Hold the ting’s handle while you speak.", systemImage: "waveform")
                        Label("Release the handle to finish dictation.", systemImage: "checkmark")
                    }
                }
                .formStyle(.grouped)
                .tabItem { Label("Get Started", systemImage: "sparkles") }

                Form {
                    Section {
                        LabeledContent("Connection", value: "USB or audio cable")
                        Text("Connect your ting with USB to set it up for the first time.").fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.secondary)
                        Button("Set Up Connected ting…", action: configureDevice)
                    } header: { Text("Your ting").fixedSize(horizontal: false, vertical: true) } footer: {
                        Text("Setup installs the controller software on your ting. Keep it connected until setup finishes.").fixedSize(horizontal: false, vertical: true)
                    }
                    Section("After setup") {
                        Text("Use USB at your desk, or connect the ting’s audio output to a line input on your Mac.").fixedSize(horizontal: false, vertical: true)
                        Text("tinker stays in the menu bar. Open its menu to check the connection or choose an input device.").fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .tabItem { Label("Device", systemImage: "cable.connector") }

                Form {
                    Section("How dictation works") {
                        Text("tinker uses the current app’s dictation shortcut when one is configured.").fixedSize(horizontal: false, vertical: true)
                        Text("Otherwise, it uses a running transcription app, then falls back to built-in dictation.").fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.secondary)
                    }
                    Section("Customize") {
                        Button("Open Configuration…") { NSWorkspace.shared.open(ConfigStore.configURL) }
                        Button("View Default Configuration…") { NSWorkspace.shared.open(ConfigStore.defaultConfigURL) }
                    }
                    Section("Permission trouble?") {
                        Text("If Accessibility is enabled in System Settings but shortcuts don’t work, repair its permission and allow access again.").fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.secondary)
                        Button("Repair Accessibility…") { permissions.repairAccessibility {} }
                    }
                }
                .formStyle(.grouped)
                .tabItem { Label("Help", systemImage: "questionmark.circle") }
            }.padding(.horizontal, 16).padding(.bottom, 16)
        }
        .frame(width: 580, height: 590)
        .onAppear(perform: updatePermissions)
        .onReceive(refresh) { _ in updatePermissions() }
    }

    private func permissionRow(_ title: String, detail: String, symbol: String,
                               granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            } else {
                Button("Allow…", action: action)
                    .accessibilityLabel("Allow \(title)")
            }
        }.padding(.vertical, 3)
    }

    private func updatePermissions() {
        permissions.refresh()
        microphone = permissions.mic == .granted
        accessibility = permissions.axTrusted
    }
}
