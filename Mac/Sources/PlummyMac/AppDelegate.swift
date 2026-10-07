import AppKit
import Carbon.HIToolbox
import PlummyShared

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let overlay = CursorOverlay()
    private let server = PhoneServer()
    private var statusItem: NSStatusItem!
    private lazy var host = RealtimeHost(overlay: overlay)
    private var hideSignal: DispatchSourceSignal?
    private var showSignal: DispatchSourceSignal?

    /// SIGUSR1 hides the cursor overlay, SIGUSR2 shows it — so screen automation can drive other apps
    /// without quitting Plummy (`pkill -USR1 -f PlummyMac` to hide, `pkill -USR2 -f PlummyMac` to show).
    private func setupOverlaySignals() {
        signal(SIGUSR1, SIG_IGN)
        signal(SIGUSR2, SIG_IGN)
        let hide = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        hide.setEventHandler { [weak self] in self?.overlay.setHidden(true) }
        hide.resume()
        hideSignal = hide
        let show = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        show.setEventHandler { [weak self] in self?.overlay.setHidden(false) }
        show.resume()
        showSignal = show
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.registerBundled()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuIcon.make()
        statusItem.button?.toolTip = "Plummy"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        overlay.onFace = { [weak self] face in self?.server.send(face) }
        overlay.start()
        setupOverlaySignals()
        showDemoBubbleIfAsked()
        checkPermissions()
        if let path = ProcessInfo.processInfo.environment["PLUMMY_DEMO_TRANSCRIBE"], let audio = FileManager.default.contents(atPath: path) {
            // Transcribes an audio file into a throwaway notes folder, prints the lines and quits.
            Task {
                let out = ProcessInfo.processInfo.environment["PLUMMY_DEMO_TRANSCRIBE_OUT"] ?? "/tmp/plummy-demo-transcript.txt"
                do {
                    let result = try await MeetingNotes.transcribe(audio: audio, session: "demo0000", index: 1, sessionStarted: Date())
                    let lines = result.segments.map { "[\($0.start)] \($0.speaker): \($0.text)" }.joined(separator: "\n")
                    for s in result.segments { print("[\(s.start)] \(s.speaker): \(s.text)") }
                    try? (lines.isEmpty ? "(empty transcription)" : lines).write(toFile: out, atomically: true, encoding: .utf8)
                    try? FileManager.default.removeItem(at: result.folder)
                } catch {
                    print("failed:", error)
                    try? "failed: \(error.localizedDescription)".write(toFile: out, atomically: true, encoding: .utf8)
                }
                exit(0)
            }
        }
        if let question = ProcessInfo.processInfo.environment["PLUMMY_DEMO_RESEARCH"] {
            host.demoResearch(question, out: ProcessInfo.processInfo.environment["PLUMMY_DEMO_OUT"] ?? "/tmp/plummy-report")
        }
        if ProcessInfo.processInfo.environment["PLUMMY_DEMO_CLAUDE"] != nil {
            // One trivial Claude round-trip to confirm the key and measure latency + tokens, then quit.
            Task {
                let out = ProcessInfo.processInfo.environment["PLUMMY_DEMO_CLAUDE_OUT"] ?? "/tmp/plummy-claude-ping.txt"
                let result = await AnthropicClient.ping()
                try? result.write(toFile: out, atomically: true, encoding: .utf8)
                exit(0)
            }
        }
        if ProcessInfo.processInfo.environment["PLUMMY_DEMO_JOURNAL"] != nil {
            // Drive the real Journal through one representative turn so the output can be checked
            // against the evidence-tier `ev` verifier; write the reply (the subject) out for binding.
            Task { @MainActor in
                let reply = "That's the Weather app, up top."
                Journal.shared.beginTurn(question: "what's this app?", recalled: ["Lives in Barnhart, Missouri"])
                Journal.shared.note(tool: "look_at_screen", label: "Looked at the screen", result: "frontmost: Weather; L1 \"Barnhart\"; W3 \"72°\"", screen: true)
                Journal.shared.note(tool: "open_app", label: "Opened Weather", result: "Opened Weather.")
                Journal.shared.endTurn(reply: reply)
                let out = ProcessInfo.processInfo.environment["PLUMMY_DEMO_JOURNAL_OUT"] ?? "/tmp/plummy-journal-reply.txt"
                try? reply.write(toFile: out, atomically: true, encoding: .utf8)
                try? await Task.sleep(for: .milliseconds(600))  // let the write queue flush
                exit(0)
            }
        }
        server.onPhonesChanged = { [weak self] names in
            self?.refreshIcon()
            if names.isEmpty, self?.host.awake == true { self?.host.setAwake(false) }
        }
        server.onRequest = { [weak self] packet, reply in self?.host.handle(packet, reply: reply) }
        server.pairingPSK = Pairing.psk(from: Self.pairingCode())
        server.start()
        host.onChange = { [weak self] in self?.refreshIcon() }

        // ⌥Space wakes her up or puts her back to sleep (same as double tapping her on the phone).
        HotKeys.shared.register(keyCode: kVK_Space, modifiers: optionKey) { [weak self] in self?.toggleAwake() }
        // ⌃⌥P point here, ⌃⌥F follow mouse, ⌃⌥D stop pointing, ⌃⌥H hide, ⌃⌥T talk test.
        HotKeys.shared.register(keyCode: kVK_ANSI_P) { [weak self] in self?.pointHere() }
        HotKeys.shared.register(keyCode: kVK_ANSI_F) { [weak self] in self?.toggleFollow() }
        HotKeys.shared.register(keyCode: kVK_ANSI_D) { [weak self] in self?.overlay.goHome() }
        HotKeys.shared.register(keyCode: kVK_ANSI_H) { [weak self] in self?.toggleShow() }
        HotKeys.shared.register(keyCode: kVK_ANSI_T) { [weak self] in self?.overlay.talkTest() }
        // ⌃⌥S stops her using the computer right away.
        HotKeys.shared.register(keyCode: kVK_ANSI_S) { [weak self] in self?.stopActions() }
        // ⌃⌥Z undoes the last reversible thing she did.
        HotKeys.shared.register(keyCode: kVK_ANSI_Z) { [weak self] in self?.undoLastAction() }
        // ⌃⌥Y confirms a risky action she's staged (Send, Delete, Buy…).
        HotKeys.shared.register(keyCode: kVK_ANSI_Y) { [weak self] in self?.host.confirmPending() }

        // Plummy's brain is local (Ollama) — no OpenAI key needed, so no key prompt on launch.
    }

    private func refreshIcon() {
        statusItem.button?.appearsDisabled = server.phoneNames.isEmpty
    }

    // MARK: Actions

    @objc private func pointHere() {
        let m = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first else { return }
        overlay.mode = .pinned(CGPoint(x: m.x - screen.frame.minX, y: screen.frame.maxY - m.y))
    }

    @objc private func undoLastAction() {
        Task { @MainActor in
            let result = await self.host.undoLast()
            self.overlay.view.bubble(result, life: 2)
        }
    }

    @objc private func toggleConfirmRisky() { settings.confirmRisky.toggle() }

    @objc private func toggleJournal() { settings.journalActions.toggle() }

    @objc private func toggleFollow() {
        settings.followMouse.toggle()
        overlay.goHome()
    }

    @objc private func dock() { overlay.goHome() }

    /// For checking the speech bubble's look: PLUMMY_DEMO_BUBBLE=top|middle|home shows a sample reply.
    private func showDemoBubbleIfAsked() {
        guard let where_ = ProcessInfo.processInfo.environment["PLUMMY_DEMO_BUBBLE"],
              let size = NSScreen.screens.first?.frame.size else { return }
        let y: CGFloat = where_ == "top" ? 40 : size.height * 0.55
        let thing = CGRect(x: size.width * 0.3, y: y, width: 90, height: 22)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if where_ != "home" {
                self.overlay.mode = .pinned(CGPoint(x: thing.midX, y: thing.maxY + 3))
                self.overlay.view.speechTarget = thing
            }
            self.overlay.view.caption = ProcessInfo.processInfo.environment["PLUMMY_DEMO_TEXT"]
                ?? "That's the prompt box, where you type to Claude. Cheeky little thing."
        }
        // PLUMMY_DEMO_OUT=path.png saves a picture of the overlay (on dark grey) and quits.
        if let out = ProcessInfo.processInfo.environment["PLUMMY_DEMO_OUT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let view = self.overlay.view
                let scale: CGFloat = 1
                let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
                ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
                ctx.fill(CGRect(x: thing.minX, y: view.bounds.height - thing.maxY, width: thing.width, height: thing.height))
                ctx.scaleBy(x: scale, y: scale)
                view.layer?.presentation()?.render(in: ctx) ?? view.layer?.render(in: ctx)
                if let image = ctx.makeImage() {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                exit(0)
            }
        }
    }
    @objc private func toggleShow() { settings.showCursor.toggle() }
    @objc private func toggleGlow() { settings.glow.toggle() }
    @objc private func setTrail(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let trail = PointerTrail(rawValue: raw) { settings.trail = trail }
    }
    @objc private func talkTest() { overlay.talkTest() }

    @objc private func setSize(_ item: NSMenuItem) { settings.cursorSize = Double(item.tag) }
    @objc private func setPhonePosition(_ item: NSMenuItem) { settings.phonePosition = Double(item.tag) / 100 }
    @objc private func toggleAwake() {
        server.broadcast(Packet(command: host.awake ? "sleep" : "wake"))
    }

    /// On launch, asks for whatever she still needs (so Plummy shows up in those Settings lists),
    /// and keeps a small status file so it's easy to check what's allowed.
    private func checkPermissions() {
        guard ProcessInfo.processInfo.environment["PLUMMY_DEMO_OUT"] == nil else { return }
        if settings.computerControl && !ComputerControl.isTrusted { ComputerControl.askForPermission() }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        MeetingNotes.primePermission()
        let status = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plummy/status.txt")
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            let text = "accessibility=\(ComputerControl.isTrusted) screenRecording=\(CGPreflightScreenCaptureAccess()) computerControl=\(Settings.shared.computerControl)\n"
            try? text.write(to: status, atomically: true, encoding: .utf8)
        }.fire()
    }

    @objc private func openNotes() {
        try? FileManager.default.createDirectory(at: MeetingNotes.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(MeetingNotes.root)
    }

    @objc private func openJournal() {
        NSWorkspace.shared.open(Journal.root)
    }

    /// The pairing code shown on the Mac and typed into the phone — created once, then remembered.
    static func pairingCode() -> String {
        if let code = Keychain.get(.pairing) { return code }
        let code = Pairing.newCode()
        Keychain.set(.pairing, code)
        return code
    }

    @objc private func showPairingCode() {
        let alert = NSAlert()
        alert.messageText = "Plummy pairing code"
        alert.informativeText = """
        Type this into Plummy on your iPhone to pair it with this Mac:

        \(Self.pairingCode())

        Only a phone with this code can connect, and everything between them is encrypted. Make a new code to unpair every phone (you'll re-enter it on the iPhone).
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "New Code…")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            let code = Pairing.newCode()
            Keychain.set(.pairing, code)
            server.rekey(Pairing.psk(from: code))
            showPairingCode()
        }
    }

    @objc private func stopActions() {
        host.stopActions()
    }

    @objc private func toggleComputerControl() {
        settings.computerControl.toggle()
        if settings.computerControl && !ComputerControl.isTrusted { ComputerControl.askForPermission() }
        restartIfAwake()  // her tools change with this switch
    }

    @objc private func allowComputerControl() {
        ComputerControl.askForPermission()
        ComputerControl.openAccessibilitySettings()
    }

    /// Wakes her again so a new personality or set of tools takes effect right away.
    private func restartIfAwake() {
        guard host.awake else { return }
        server.broadcast(Packet(command: "sleep"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.server.broadcast(Packet(command: "wake")) }
    }

    @objc private func editPersonality() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Her Personality"
        alert.informativeText = "Describe who she is and how she talks. How she looks at and points at your screen stays built in."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.autoresizingMask = [.width]
        text.isRichText = false
        text.font = NSFont.systemFont(ofSize: 13)
        text.string = RealtimeHost.personality
        text.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset to Default")
        alert.window.initialFirstResponder = text
        switch alert.runModal() {
        case .alertFirstButtonReturn: RealtimeHost.personality = text.string
        case .alertThirdButtonReturn: RealtimeHost.personality = ""
        default: return
        }
        restartIfAwake()
    }

    @objc private func editAnthropicKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Anthropic API Key"
        alert.informativeText = """
        Paste your Anthropic key to let Plummy think with Claude instead of the local model — smarter at \
        multi-step, and it can see the screen. While a key is set, screen text and screenshots are sent to \
        Anthropic and it bills your key. Saved privately on this Mac. Leave empty and Save to clear it and go \
        back to the fully-local brain.
        """
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = Keychain.get(.anthropic) == nil ? "sk-ant-…" : "Key saved (using Claude). Empty + Save to go local."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Keychain.set(.anthropic, field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func editVisionModel() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Local Vision Model"
        alert.informativeText = """
        Give the offline (Ollama) brain eyes. The text model keeps running the show and its tools; the \
        vision model gets one look at each screenshot and tells it what's on screen and where. Works with \
        any Ollama vision model — it never needs tool calls. qwen3-vl:2b aced the grounding test here; \
        pull it first in Terminal: ollama pull qwen3-vl:2b. Leave empty and Save for the text-only brain, \
        which works off the screen's text alone. Everything stays on this Mac either way.
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = OllamaClient.visionModel
        field.placeholderString = "qwen3-vl:2b  (empty = text-only)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ollamaVisionModel")
    }

    /// Flip between the local brain and Claude. With no key yet, turning it on opens the key dialog.
    @objc private func toggleClaudeBrain() {
        if Keychain.get(.anthropic) == nil {
            settings.useClaudeBrain = true
            editAnthropicKey()
        } else {
            settings.useClaudeBrain.toggle()
        }
    }

    @objc private func setMood(_ item: NSMenuItem) {
        if let mood = item.representedObject as? String, let m = Mood(rawValue: mood) { settings.mood = m }
    }

    @objc private func showMemory() {
        let facts = Memory.facts()
        let alert = NSAlert()
        alert.messageText = "What Plummy remembers"
        if facts.isEmpty {
            alert.informativeText = "Nothing yet. She'll remember things you tell her, across sessions."
            alert.addButton(withTitle: "OK")
        } else {
            alert.informativeText = facts.map { "• \($0)" }.joined(separator: "\n")
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Forget Everything")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { Memory.forgetAll() }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let phones = server.phoneNames
        let status = NSMenuItem(title: phones.isEmpty ? "Waiting for the phone app…" : "Phone connected: \(phones.joined(separator: ", "))",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let wake = NSMenuItem(title: host.awake ? "Go to Sleep (Follow Mode)" : "Wake Up and Talk",
                              action: #selector(toggleAwake), keyEquivalent: " ")
        wake.keyEquivalentModifierMask = [.option]
        wake.target = self
        wake.isEnabled = !phones.isEmpty
        menu.addItem(wake)
        menu.addItem(.separator())

        let control = item("Let Her Use the Computer", #selector(toggleComputerControl))
        control.state = settings.computerControl ? .on : .off
        menu.addItem(control)
        if settings.computerControl && !ComputerControl.isTrusted {
            menu.addItem(item("Allow Clicking and Typing (Accessibility)…", #selector(allowComputerControl)))
        }
        menu.addItem(item("Stop Her", #selector(stopActions), key: "s"))
        menu.addItem(item("Undo Last Action", #selector(undoLastAction), key: "z"))
        let confirm = item("Confirm Risky Actions", #selector(toggleConfirmRisky))
        confirm.state = settings.confirmRisky ? .on : .off
        confirm.toolTip = "Pause for a ⌃⌥Y confirm before she clicks Send, Delete, Buy, Submit, etc."
        menu.addItem(confirm)
        let journal = item("Keep an Action Journal", #selector(toggleJournal))
        journal.state = settings.journalActions ? .on : .off
        journal.toolTip = "Record what she does and reads, tiered ran/read/told/recalled/inferred, in ~/Documents/Plummy Journal. Local only."
        menu.addItem(journal)
        menu.addItem(.separator())

        let point = item("Point Here", #selector(pointHere), key: "p")
        menu.addItem(point)
        let follow = item("Eyes Follow My Mouse", #selector(toggleFollow), key: "f")
        follow.state = settings.followMouse ? .on : .off
        menu.addItem(follow)
        menu.addItem(item("Stop Pointing", #selector(dock), key: "d"))
        menu.addItem(item("Talk Test", #selector(talkTest), key: "t"))
        menu.addItem(.separator())

        let moodMenu = NSMenu()
        for mood in Mood.allCases where mood != .talking && mood != .pointing && mood != .sleepy {
            let m = item(mood.title, #selector(setMood(_:)))
            m.representedObject = mood.rawValue
            m.state = settings.mood == mood ? .on : .off
            moodMenu.addItem(m)
        }
        menu.addItem(submenu("Mood", moodMenu))

        let sizeMenu = NSMenu()
        for (name, size) in [("Small", 48), ("Medium", 72), ("Large", 96), ("Huge", 120)] {
            let s = item("\(name) (\(size) pt)", #selector(setSize(_:)))
            s.tag = size
            s.state = Int(settings.cursorSize) == size ? .on : .off
            sizeMenu.addItem(s)
        }
        menu.addItem(submenu("Cursor Size", sizeMenu))

        let phoneMenu = NSMenu()
        for (name, pos) in [("Left", 20), ("Center", 50), ("Right", 80)] {
            let p = item(name, #selector(setPhonePosition(_:)))
            p.tag = pos
            p.state = Int((settings.phonePosition * 100).rounded()) == pos ? .on : .off
            phoneMenu.addItem(p)
        }
        menu.addItem(submenu("Phone Sits Under", phoneMenu))

        menu.addItem(item("Open Meeting Notes", #selector(openNotes)))
        menu.addItem(item("Open Action Journal", #selector(openJournal)))
        menu.addItem(item("Personality…", #selector(editPersonality)))
        menu.addItem(item("What She Remembers…", #selector(showMemory)))
        menu.addItem(item("Anthropic API Key…", #selector(editAnthropicKey)))
        let claude = item("Think with Claude", #selector(toggleClaudeBrain))
        claude.state = (settings.useClaudeBrain && Keychain.get(.anthropic) != nil) ? .on : .off
        claude.toolTip = "On: smarter, sees the screen, uses your Anthropic key (cloud). Off: fully-local brain."
        menu.addItem(claude)
        let vision = item("Local Vision Model…", #selector(editVisionModel))
        vision.state = OllamaClient.visionModel.isEmpty ? .off : .on
        vision.toolTip = "Give the offline (Ollama) brain eyes with a local vision model. Empty = text-only."
        menu.addItem(vision)
        menu.addItem(item("Pairing Code…", #selector(showPairingCode)))
        menu.addItem(.separator())

        let trailMenu = NSMenu()
        for trail in PointerTrail.allCases {
            let t = item(trail.title, #selector(setTrail(_:)))
            t.representedObject = trail.rawValue
            t.state = settings.trail == trail ? .on : .off
            trailMenu.addItem(t)
        }
        menu.addItem(submenu("Pointer Trail", trailMenu))

        let glow = item("Cursor Glow", #selector(toggleGlow))
        glow.state = settings.glow ? .on : .off
        menu.addItem(glow)
        let show = item("Show Cursor", #selector(toggleShow), key: "h")
        show.state = settings.showCursor ? .on : .off
        menu.addItem(show)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Plummy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Menu item that shows its global shortcut (⌃⌥ + key) when given one.
    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = [.control, .option]
        item.target = self
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// The little plum blob with eyes for the menu bar.
enum MenuIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: true) { rect in
            let body = NSBezierPath(ovalIn: NSRect(x: 1, y: 2, width: 20, height: 16))
            NSGradient(colors: Palette.gradient.map { NSColor(hex: $0) })?.draw(in: body, angle: -60)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 5, y: 6, width: 5.5, height: 5.5)).fill()
            NSBezierPath(ovalIn: NSRect(x: 11.5, y: 6, width: 5.5, height: 5.5)).fill()
            NSColor(hex: Palette.ink).setFill()
            NSBezierPath(ovalIn: NSRect(x: 6.3, y: 6.8, width: 3, height: 3)).fill()
            NSBezierPath(ovalIn: NSRect(x: 12.8, y: 6.8, width: 3, height: 3)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
