import SwiftUI

extension Color {
    /// SoundCloud orange, #FF5500.
    static let sc = Color(red: 1, green: 0.333, blue: 0)
    static let scSurface = Color(white: 0.09)
}

/// A black label box behind white text, as SoundCloud prints titles over artwork.
struct LabelBox: ViewModifier {
    var fill: Color = .black.opacity(0.85)
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(fill)
    }
}

extension View {
    func labelBox(_ fill: Color = .black.opacity(0.85)) -> some View { modifier(LabelBox(fill: fill)) }
}

// MARK: waveform

private struct WaveformJSON: Decodable {
    let height: Int?
    let samples: [Int]
}

/// Waveform samples per track, normalised to 0...1, cached for the session.
@MainActor
final class WaveformStore {
    static let shared = WaveformStore()
    private var cache: [Int: [Float]] = [:]

    func samples(for t: SCTrack) async -> [Float]? {
        if let s = cache[t.id] { return s }
        guard var s = t.waveformUrl, !s.isEmpty else { return nil }
        // Old tracks list the PNG rendition; the same name with .json is the data.
        if s.hasSuffix(".png") { s = String(s.dropLast(4)) + ".json" }
        guard let url = URL(string: s),
              let res = try? await URLSession.shared.data(from: url),
              let w = try? JSONDecoder().decode(WaveformJSON.self, from: res.0),
              !w.samples.isEmpty
        else { return nil }
        let top = Float(max(w.height ?? 0, w.samples.max() ?? 1, 1))
        let v = w.samples.map { Float($0) / top }
        cache[t.id] = v
        return v
    }
}

/// Picks `count` bars out of the samples, each the loudest sample of its slice.
func resample(_ s: [Float], to count: Int) -> [Float] {
    guard count > 0 else { return [] }
    guard !s.isEmpty else { return Array(repeating: 0.25, count: count) }
    return (0..<count).map { i in
        let a = i * s.count / count
        let b = max(a + 1, (i + 1) * s.count / count)
        return s[a..<min(b, s.count)].max() ?? 0
    }
}

/// SoundCloud's scrubber: the waveform, played part in orange, with a dim reflection below.
struct WaveformScrubber: View {
    let track: SCTrack?
    @ObservedObject var clock: PlaybackClock
    let onSeek: (Double) -> Void

    @State private var samples: [Float] = []
    @State private var drag: Double?

    private let bar: CGFloat = 2
    private let gap: CGFloat = 1

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let baseline = h * 0.68
            let progress = drag ?? (clock.duration > 0 ? min(1, clock.time / clock.duration) : 0)
            let bars = resample(samples, to: Int(w / (bar + gap)))

            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    for (i, v) in bars.enumerated() {
                        let x = CGFloat(i) * (bar + gap)
                        let played = x / size.width < progress
                        let up = max(2, CGFloat(v) * baseline)
                        let down = max(1, CGFloat(v) * (size.height - baseline) * 0.9)
                        ctx.fill(Path(CGRect(x: x, y: baseline - up, width: bar, height: up)),
                                 with: .color(played ? .sc : .white.opacity(0.85)))
                        ctx.fill(Path(CGRect(x: x, y: baseline + 1, width: bar, height: down)),
                                 with: .color(played ? Color.sc.opacity(0.45) : .white.opacity(0.3)))
                    }
                }

                let shown = progress * clock.duration
                HStack(spacing: 0) {
                    Text(formatDuration(shown)).foregroundColor(drag == nil ? .white : .sc).labelBox()
                    Text(formatDuration(clock.duration)).foregroundColor(.gray).labelBox()
                }
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .fixedSize()
                .position(x: min(max(w * progress, 50), w - 50), y: baseline)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag = min(1, max(0, $0.location.x / w)) }
                    .onEnded { v in
                        let f = min(1, max(0, v.location.x / w))
                        onSeek(f * clock.duration)
                        drag = nil
                    }
            )
        }
        .task(id: track?.id) {
            samples = []
            if let track, let s = await WaveformStore.shared.samples(for: track) {
                withAnimation(.easeOut(duration: 0.25)) { samples = s }
            }
        }
    }
}

// MARK: cards

/// A square track card for horizontal carousels.
struct TrackCard: View {
    let track: SCTrack
    var size: CGFloat = 140
    let onTap: () -> Void
    @EnvironmentObject private var player: Player

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .bottomTrailing) {
                    Artwork(url: track.artwork("t300x300"), size: size, corner: 3)
                    if player.current?.id == track.id {
                        Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                            .font(.caption.bold()).foregroundColor(.white)
                            .padding(6).background(Circle().fill(Color.sc)).padding(6)
                    }
                }
                Text(track.title ?? "—").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(track.user?.name ?? "").font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
        .contextMenu { TrackMenu(track: track) }
    }
}

/// A section title in SoundCloud's style: bold, white, left-aligned.
struct SectionTitle: View {
    let text: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.system(size: 20, weight: .bold))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.footnote).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }
}
