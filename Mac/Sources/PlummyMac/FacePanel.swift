import AppKit
import SwiftUI
import PlummyShared

/// Her face on the Mac — the same renderer the phone runs, in a small floating panel.
///
/// This is `FaceView` from `Shared/`, so the Mac and the phone draw from one file: change her face
/// once and both bodies follow. The panel is borderless and non-activating, so it never steals focus
/// or a Dock slot; she just sits there, watches your pointer, and boops back.
@MainActor
final class FacePanel {
    /// Drawn on her 844 × 390 landscape design, so nothing gets cropped.
    private static let size = NSSize(width: 320, height: 148)
    private static let defaultsKey = "showFacePanel"
    private static let autosaveName = "PlummyFacePanel"

    /// Whether she shows her face on the Mac. On unless the user turns it off.
    static var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    let animator = FaceAnimator()
    private var panel: NSPanel?
    private var moveMonitor: Any?
    private var moodReset: DispatchWorkItem?
    private var hiddenForAutomation = false

    // MARK: - Showing and hiding

    func show() {
        if let panel {
            panel.orderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.title = "Plummy"

        let host = NSHostingView(rootView: FaceView(animator: animator))
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.autoresizingMask = [.width, .height]

        let container = BoopView(frame: host.frame)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.cornerRadius = 20
        container.layer?.masksToBounds = true
        container.onBoop = { [weak self] in self?.boop() }
        container.addSubview(host)
        panel.contentView = container

        // Restore where she was last left. Only if there's nothing saved do we pick a corner —
        // `frame.origin == .zero` is not a reliable "unplaced" test, AppKit nudges borderless panels.
        let restored = panel.setFrameUsingName(Self.autosaveName)
        panel.setFrameAutosaveName(Self.autosaveName)
        if !restored { moveToDefaultCorner(panel) }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.55
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        startWatchingThePointer()
    }

    func hide() {
        panel?.orderOut(nil)
        stopWatchingThePointer()
    }

    /// Mirrors the cursor overlay's SIGUSR1/SIGUSR2 behaviour, so screen automation can drive other
    /// apps without her panel sitting in the way (`pkill -USR1 -f PlummyMac` to hide).
    func setHidden(_ hidden: Bool) {
        hiddenForAutomation = hidden
        guard Self.enabled else { return }
        if hidden { panel?.orderOut(nil) } else { panel?.orderFrontRegardless() }
    }

    /// Bottom-right of the screen, clear of the Dock. `NSScreen.main` is nil for a menu-bar app with
    /// no key window, so fall back to the first screen rather than leaving her wherever AppKit put her.
    private func moveToDefaultCorner(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 24
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - Self.size.width - margin,
            y: visible.minY + margin))
    }

    // MARK: - Life

    /// The face state the Mac is already sending the phone, so both screens agree on her mood.
    func receive(_ face: FaceState) {
        animator.receive(face, at: Date().timeIntervalSinceReferenceDate)
    }

    private func startWatchingThePointer() {
        guard moveMonitor == nil else { return }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.lookAtThePointer()
        }
        lookAtThePointer()
    }

    private func stopWatchingThePointer() {
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
        moveMonitor = nil
        animator.touchGaze = nil
    }

    /// Her eyes follow the mouse, easing off once it's well away from her.
    private func lookAtThePointer() {
        guard let panel, panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let centre = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let reach: CGFloat = 520  // how far away the mouse still pulls her eyes fully across
        let dx = Double(max(-1, min(1, (mouse.x - centre.x) / reach)))
        // AppKit's y grows upward; her gaze units have y growing down.
        let dy = Double(max(-1, min(1, (centre.y - mouse.y) / reach)))
        animator.touchGaze = CGPoint(x: dx, y: dy)
    }

    private func boop() {
        Chirp.shared.play(syllables: Int.random(in: 2...3))
        moodReset?.cancel()
        // A mood change makes the animator bounce and pop her pupils all on its own.
        animator.localMood = .happy
        let reset = DispatchWorkItem { [weak self] in self?.animator.localMood = nil }
        moodReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: reset)
    }
}

// MARK: - The panel's content

/// Drags the panel around, and counts a click that didn't drag as a boop.
private final class BoopView: NSView {
    var onBoop: (() -> Void)?
    private var dragOrigin: NSPoint?
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        dragOrigin = NSEvent.mouseLocation
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - dragOrigin.x
        let dy = now.y - dragOrigin.y
        if !dragged && (abs(dx) + abs(dy)) < 3 { return }
        dragged = true
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x + dx, y: window.frame.origin.y + dy))
        self.dragOrigin = now
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        guard !dragged else {
            window?.saveFrame(usingName: "PlummyFacePanel")  // keep where she was dragged
            return
        }
        onBoop?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
