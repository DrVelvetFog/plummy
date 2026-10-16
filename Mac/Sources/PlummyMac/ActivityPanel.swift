import AppKit
import PlummyShared
import SwiftUI

/// A small, honest "what Plummy's doing right now" card with a Stop button. It appears while she
/// acts (fed by every Journal action label) and fades out after a few idle seconds. Watch her work,
/// grab the wheel whenever you want.
@MainActor
final class ActivityPanel {
    static var enabled: Bool {
        get { Settings.shared.activityPanel }
        set { Settings.shared.activityPanel = newValue }
    }

    private var panel: NSPanel?
    private let model = ActivityModel()
    private var hideTimer: Timer?
    /// Called when the user clicks Stop (wired to the same stop as ⌃⌥S).
    var onStop: (() -> Void)?

    /// Show the latest thing she's doing. Called from Journal for every action.
    func update(_ label: String) {
        guard Self.enabled, !label.isEmpty else { return }
        model.current = label
        model.history = Array((model.history + [label]).suffix(4))
        if panel == nil { makePanel() }
        layout()
        panel?.orderFrontRegardless()
        scheduleHide(after: 5)
    }

    func hide() {
        hideTimer?.invalidate(); hideTimer = nil
        panel?.orderOut(nil)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.panel?.orderOut(nil) }
        }
    }

    private func makePanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)  // above her cursor overlay
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: ActivityCard(model: model, onStop: { [weak self] in self?.onStop?() }))
        self.panel = panel
    }

    /// Top-left, out of the way of the research card (which sits top-right).
    private func layout() {
        guard let panel, let screen = NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        let width: CGFloat = 300
        let extra = CGFloat(max(0, min(3, model.history.count - 1))) * 20
        let height: CGFloat = 86 + extra
        panel.setFrame(NSRect(x: v.minX + 24, y: v.maxY - height - 24, width: width, height: height), display: true)
    }
}

final class ActivityModel: ObservableObject {
    @Published var current: String = ""
    @Published var history: [String] = []
}

private struct ActivityCard: View {
    @ObservedObject var model: ActivityModel
    var onStop: () -> Void

    private let ink = Color(nsColor: NSColor(hex: Palette.ink))
    private let berry = Color(nsColor: NSColor(hex: Palette.berry2))
    private let soft = Color(nsColor: NSColor(hex: 0x5D5873))

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(berry).frame(width: 9, height: 9)
                Text("WHAT PLUMMY'S DOING")
                    .font(.custom("IBM Plex Mono", size: 10))
                    .foregroundStyle(soft)
                Spacer(minLength: 4)
                Button(action: onStop) {
                    Text("Stop")
                        .font(.custom("IBM Plex Sans", size: 12).weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(berry))
                }
                .buttonStyle(.plain)
                .help("Stop what she's doing (same as ⌃⌥S).")
            }
            Text(model.current)
                .font(.custom("Fredoka", size: 16).weight(.medium))
                .foregroundStyle(ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(model.history.dropLast().suffix(3).reversed().enumerated()), id: \.offset) { _, past in
                Text(past)
                    .font(.custom("IBM Plex Sans", size: 12))
                    .foregroundStyle(soft)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [.white, Color(nsColor: NSColor(hex: 0xEEF0FF))], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(berry, lineWidth: 2.5))
        .padding(4)
    }
}
