import AppKit
import SwiftUI

/// Non-modal guidance: the dictation and serial run loops must keep running.
final class FloatingAlert: NSObject, NSWindowDelegate {
    private static var live: [FloatingAlert] = []
    private let panel: NSPanel
    private let model: AlertContent

    @discardableResult
    static func show(title: String, text: String, showsOK: Bool = true) -> FloatingAlert {
        let alert = FloatingAlert(title: title, text: text, showsOK: showsOK)
        live.append(alert)
        alert.panel.center()
        alert.panel.makeKeyAndOrderFront(nil)
        alert.panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        return alert
    }

    func close() { panel.close() }

    func update(text: String) {
        model.text = text
        DispatchQueue.main.async { [weak self] in self?.resizeToFit() }
    }

    private init(title: String, text: String, showsOK: Bool) {
        model = AlertContent(title: title, text: text, showsOK: showsOK)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = AppIdentity.displayName
        // Device guidance must remain visible while the user works elsewhere.
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        super.init()
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: AlertView(model: model) { [weak self] in self?.close() })
        resizeToFit()
    }

    private func resizeToFit() {
        guard let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let top = panel.frame.maxY
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
    }

    func windowWillClose(_ notification: Notification) {
        Self.live.removeAll { $0 === self }
    }
}

private final class AlertContent: ObservableObject {
    let title: String
    @Published var text: String
    let showsOK: Bool
    init(title: String, text: String, showsOK: Bool) {
        self.title = title
        self.text = text
        self.showsOK = showsOK
    }
}

private struct AlertView: View {
    @ObservedObject var model: AlertContent
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: model.showsOK ? "info.circle" : "cable.connector")
                    .font(.system(size: 28)).foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(model.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(model.text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.body)
            if model.showsOK {
                HStack {
                    Spacer()
                    Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
                }
            } else {
                Divider()
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Keep your ting connected.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(width: 480, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
