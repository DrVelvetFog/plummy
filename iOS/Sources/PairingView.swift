import SwiftUI

/// Shown until the phone is paired and linked. First it asks for the pairing code from the Mac's
/// menu (so only this phone can connect, over an encrypted link); once paired, it waits for the Mac.
struct PairingView: View {
    var paired: Bool
    var rejected: Bool
    var foundMac: Bool
    var onPair: (String) -> Void
    var onPlay: () -> Void

    @State private var code = ""

    private var needsCode: Bool { !paired || rejected }

    var body: some View {
        HStack(spacing: 56) {
            SleepyBlob()
                .frame(width: 220, height: 190)

            VStack(alignment: .leading, spacing: 14) {
                if needsCode { codeEntry } else { waiting }
            }
        }
        .padding(.horizontal, 72)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    @ViewBuilder private var codeEntry: some View {
        Text("Pair with your Mac")
            .font(.fredoka(32))
            .foregroundStyle(Color(hex: 0xF4F1FA))
        Text("On your Mac, open Velvet in the menu bar, choose \u{201C}Pairing Code\u{2026}\u{201D}, and type the code here. It keeps the link private to your Mac and encrypts it.")
            .font(.plexSans(16))
            .foregroundStyle(Color(hex: Palette.inkSoft))
            .frame(maxWidth: 440, alignment: .leading)
        HStack(spacing: 10) {
            TextField("XXXX-XXXX-XXXX", text: $code)
                .font(.plexMono(18))
                .foregroundStyle(Color(hex: 0xF4F1FA))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.join)
                .onSubmit(pair)
                .padding(.horizontal, 14)
                .frame(width: 250, height: 48)
                .background(Color(hex: Palette.panel), in: RoundedRectangle(cornerRadius: 14))
            Button(action: pair) {
                Text("Pair")
                    .font(.plexSans(16).weight(.semibold))
                    .foregroundStyle(Color(hex: 0xF4F1FA))
                    .padding(.horizontal, 22)
                    .frame(minHeight: 48)
                    .background(Color(hex: Palette.berry3), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .opacity(code.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
        .padding(.top, 2)
        if rejected {
            Text("That code didn't match. Check it on the Mac and try again.")
                .font(.plexSans(14))
                .foregroundStyle(Color(hex: 0xFF9AD0))
        }
        playButton
    }

    @ViewBuilder private var waiting: some View {
        Text("Wake me up from your Mac")
            .font(.fredoka(32))
            .foregroundStyle(Color(hex: 0xF4F1FA))
        Text("Open Velvet in your Mac's menu bar. Keep both on the same Wi-Fi and I'll find it.")
            .font(.plexSans(16))
            .foregroundStyle(Color(hex: Palette.inkSoft))
            .frame(maxWidth: 380, alignment: .leading)
        HStack(spacing: 10) {
            ProgressView().tint(Color(hex: Palette.berry1))
            Text(foundMac ? "Connecting\u{2026}" : "Looking for your Mac")
                .font(.plexMono(13))
                .foregroundStyle(Color(hex: Palette.inkSoft))
        }
        .padding(.top, 4)
        playButton
    }

    private var playButton: some View {
        Button(action: onPlay) {
            Text("Play without the Mac")
                .font(.plexSans(15).weight(.semibold))
                .foregroundStyle(Color(hex: 0xF4F1FA))
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .background(Color(hex: Palette.panel), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func pair() {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onPair(trimmed)
    }
}

private struct SleepyBlob: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                BlobShape()
                    .fill(BlobShape.linear)
                    .overlay(BlobShape().fill(RadialGradient(colors: [.white.opacity(0.5), .white.opacity(0)],
                                                             center: UnitPoint(x: 0.3, y: 0.22), startRadius: 0, endRadius: 80)))
                    .opacity(0.9)
                HStack(spacing: 26) {
                    Capsule().fill(Color(hex: Palette.ink)).frame(width: 46, height: 7)
                    Capsule().fill(Color(hex: Palette.ink)).frame(width: 46, height: 7)
                }
                .offset(y: -18)
                Ellipse().fill(Color(hex: Palette.nose)).frame(width: 18, height: 12).offset(x: 4, y: 21)
                Text("z").font(.fredoka(26)).foregroundStyle(Color(hex: Palette.berry3))
                    .offset(x: 110, y: -95 - 4 * sin(t * 1.5))
                Text("z").font(.fredoka(18)).foregroundStyle(Color(hex: Palette.berry4))
                    .offset(x: 128, y: -122 - 4 * sin(t * 1.5 + 1))
            }
            .scaleEffect(1 + 0.02 * sin(t * 1.1), anchor: .bottom)
        }
    }
}
