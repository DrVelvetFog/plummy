import Foundation
import Network
import CryptoKit
import Security

/// Everything the Mac and the iPhone agree on: the Bonjour service name,
/// what a "face update" looks like, and how lines of JSON travel over TCP.
public enum GooglyService {
    public static let type = "_googly._tcp"
}

public enum Mood: String, Codable, CaseIterable, Sendable {
    case listening, resting, thinking, talking, pointing, happy, sleepy

    public var title: String { rawValue.capitalized }
}

/// What the phone should show right now.
public struct FaceState: Codable, Equatable, Sendable {
    /// Where the eyes look. x: -1 left … 1 right. y: -1 up … 1 down.
    public var gazeX: Double
    public var gazeY: Double
    public var mood: Mood
    /// Voice level, 0…1. Drives the talking bounce.
    public var talk: Double

    public init(gazeX: Double = 0, gazeY: Double = 0, mood: Mood = .listening, talk: Double = 0) {
        self.gazeX = gazeX
        self.gazeY = gazeY
        self.mood = mood
        self.talk = talk
    }
}

public struct Packet: Codable, Sendable {
    public var face: FaceState?
    /// Sent once by each side after connecting, with a device name.
    public var hello: String?
    /// Voice volume 0…1. The Mac shares it, the phone sets it.
    public var volume: Double?
    /// A request or event: "testVoice" (phone→Mac), "playing"/"done" (phone→Mac), "stopSpeech" (Mac→phone).
    public var command: String?
    /// Speech audio (mp3, base64) for the phone to play.
    public var audio: String?
    /// Which speech an audio packet or a playing/done event belongs to.
    public var speech: Int?
    /// Pairs a request with its reply (tool calls, realtime tokens).
    public var callID: String?
    /// Tool name for a "tool" request.
    public var tool: String?
    /// Free text: tool arguments or output, a token, a caption.
    public var text: String?
    /// A JPEG (base64) that goes with a tool result.
    public var image: String?

    public init(face: FaceState? = nil, hello: String? = nil, volume: Double? = nil, command: String? = nil,
                audio: String? = nil, speech: Int? = nil, callID: String? = nil, tool: String? = nil,
                text: String? = nil, image: String? = nil) {
        self.face = face
        self.hello = hello
        self.volume = volume
        self.command = command
        self.audio = audio
        self.speech = speech
        self.callID = callID
        self.tool = tool
        self.text = text
        self.image = image
    }
}

/// The pairing secret that locks the phone to one Mac. The Mac shows a code in its menu; the phone
/// is typed that code once. Both derive the same key from it — used as a TLS pre-shared key, so only
/// a peer with the code can connect and all traffic is encrypted.
public enum Pairing {
    /// A fresh random pairing code, like `K7MP-9QRT-X2WF` (no look-alike I/O/0/1).
    public static func newCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let chars = bytes.map { alphabet[Int($0) % alphabet.count] }
        let s = String(chars)
        return "\(s.prefix(4))-\(s.dropFirst(4).prefix(4))-\(s.suffix(4))"
    }

    /// A 32-byte key derived from the code, ignoring case, spaces and hyphens.
    public static func psk(from code: String) -> Data {
        let norm = code.uppercased().filter { $0.isLetter || $0.isNumber }
        return Data(SHA256.hash(data: Data(("velvet-pairing-v1" + norm).utf8)))
    }
}

public extension NWParameters {
    /// Plain parameters for Bonjour discovery only (the browser just finds Macs; no TLS yet).
    static var googlyBrowse: NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }

    /// Authenticated + encrypted parameters for the real link: TLS with a pre-shared key from the
    /// pairing code. Only a peer with the same code completes the handshake (TLS 1.2, AES-128-GCM).
    static func googly(psk: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        let keyDD = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let idDD = Data("velvet".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, keyDD as __DispatchData, idDD as __DispatchData)
        if let cipher = tls_ciphersuite_t(rawValue: 0x00A8) {  // TLS_PSK_WITH_AES_128_GCM_SHA256
            sec_protocol_options_append_tls_ciphersuite(sec, cipher)
        }
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }
}

/// Newline-delimited JSON over one NWConnection. All callbacks run on the main queue.
public final class LineConnection {
    public let connection: NWConnection
    public var onPacket: ((Packet) -> Void)?
    public var onState: ((NWConnection.State) -> Void)?

    private var buffer = Data()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(_ connection: NWConnection) {
        self.connection = connection
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.onState?(state)
        }
        connection.start(queue: .main)
        receive()
    }

    public func send(_ packet: Packet) {
        guard var data = try? encoder.encode(packet) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    public func cancel() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                while let newline = self.buffer.firstIndex(of: 0x0A) {
                    let line = self.buffer[self.buffer.startIndex..<newline]
                    self.buffer.removeSubrange(self.buffer.startIndex...newline)
                    if let packet = try? self.decoder.decode(Packet.self, from: line) {
                        self.onPacket?(packet)
                    }
                }
            }
            if isComplete || error != nil {
                self.connection.cancel()
            } else {
                self.receive()
            }
        }
    }
}
