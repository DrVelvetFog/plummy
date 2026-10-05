import Foundation
import Network
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Finds the Mac app on the local network with Bonjour and keeps a connection open.
final class MacLink: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var macName: String?
    /// Every Mac running Velvet on this Wi-Fi, by its Bonjour name.
    @Published private(set) var macs: [String] = []
    /// The Mac the phone is linked to (or trying to link to).
    @Published private(set) var currentMac: String?
    /// The Mac picked in the speaker panel. Remembered, so the phone goes back to it on launch.
    @Published private(set) var preferredMac: String? = UserDefaults.standard.string(forKey: "preferredMac")
    /// Whether a pairing code (from the Mac's menu) has been saved. The link is TLS-encrypted with a key from it.
    @Published private(set) var paired: Bool = (UserDefaults.standard.string(forKey: "pairingCode") ?? "").isEmpty == false
    /// Set when the Mac is visible but the code doesn't match, so the UI can ask for it again.
    @Published var codeRejected = false
    private var handshakeFailures = 0
    private var pairingCode: String { UserDefaults.standard.string(forKey: "pairingCode") ?? "" }
    /// Commands from the Mac, like "wake" and "sleep".
    var onCommand: ((String) -> Void)?
    private var waiting: [String: (Packet?) -> Void] = [:]

    var onFace: ((FaceState) -> Void)?

    private var browser: NWBrowser?
    private var link: LineConnection?
    private var retry: DispatchWorkItem?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: GooglyService.type, domain: nil), using: .googlyBrowse)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.macs = results.compactMap(Self.serviceName).sorted()
            // Move over when the picked Mac shows up while linked to a different one.
            if let preferred = self.preferredMac, self.currentMac != preferred, self.macs.contains(preferred) {
                self.link?.cancel()
            }
            self.connectIfNeeded()
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.restart() }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        retry?.cancel()
        browser?.cancel()
        browser = nil
        link?.cancel()
        link = nil
        connected = false
    }

    private func restart() {
        stop()
        scheduleRetry()
    }

    private func scheduleRetry() {
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.browser == nil { self.start() } else { self.connectIfNeeded() }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Save the pairing code typed on the phone (from the Mac's **Pairing Code…** menu) and connect with it.
    func pair(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: "pairingCode")
        paired = !trimmed.isEmpty
        codeRejected = false
        handshakeFailures = 0
        link?.cancel()
        link = nil
        connected = false
        if browser == nil { start() } else { connectIfNeeded() }
    }

    /// Switches to another Mac and remembers the choice.
    func choose(_ name: String) {
        preferredMac = name
        UserDefaults.standard.set(name, forKey: "preferredMac")
        if currentMac != name { link?.cancel() }
        connectIfNeeded()
    }

    private static func serviceName(_ result: NWBrowser.Result) -> String? {
        if case let .service(name, _, _, _) = result.endpoint { return name }
        return nil
    }

    private func connectIfNeeded() {
        guard link == nil, !codeRejected, !pairingCode.isEmpty,
              let results = browser?.browseResults, !results.isEmpty else { return }
        let result = results.first { Self.serviceName($0) == preferredMac } ?? results.first!
        currentMac = Self.serviceName(result)
        let link = LineConnection(NWConnection(to: result.endpoint, using: .googly(psk: Pairing.psk(from: pairingCode))))
        link.onState = { [weak self, weak link] state in
            guard let self, let link, link === self.link else { return }
            switch state {
            case .ready:
                self.connected = true
                self.handshakeFailures = 0
                self.codeRejected = false
                link.send(Packet(hello: Self.deviceName))
            case .failed(let error):
                self.noteHandshake(error)
                self.dropLink()
                if !self.codeRejected { self.scheduleRetry() }
            case .cancelled:
                self.dropLink()
                if !self.codeRejected { self.scheduleRetry() }
            case .waiting(let error):
                // A wrong pairing code surfaces here as a TLS "bad MAC"; a missing Mac does not.
                self.noteHandshake(error)
                link.cancel()
            default:
                break
            }
        }
        link.onPacket = { [weak self] packet in
            if let name = packet.hello { self?.macName = name }
            if let face = packet.face { self?.onFace?(face) }
            guard let self, let command = packet.command else { return }
            if let callID = packet.callID, let done = self.waiting.removeValue(forKey: callID) {
                done(packet)
            } else {
                self.onCommand?(command)
            }
        }
        self.link = link
        link.start()
    }

    /// Counts TLS handshake failures (a mismatched pairing code); after two, flags the code as rejected
    /// so the UI can ask for it again. A missing Mac fails differently and never trips this.
    private func noteHandshake(_ error: NWError) {
        if case .tls = error {
            handshakeFailures += 1
            if handshakeFailures >= 2 { codeRejected = true }
        }
    }

    /// Clears the current link and fails any in-flight requests.
    private func dropLink() {
        connected = false
        let pending = waiting
        waiting = [:]
        pending.values.forEach { $0(nil) }
        macName = nil
        link = nil
    }

    func send(_ packet: Packet) {
        link?.send(packet)
    }

    /// Sends a request to the Mac and calls back with its reply (nil if the Mac went away).
    func request(_ packet: Packet, _ done: @escaping (Packet?) -> Void) {
        guard let link, connected else { done(nil); return }
        var packet = packet
        let id = UUID().uuidString
        packet.callID = id
        waiting[id] = done
        link.send(packet)
    }

    private static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Phone"
        #endif
    }
}
