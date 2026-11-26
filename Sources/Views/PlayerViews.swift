import AVKit
import SwiftUI

struct MiniPlayer: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        if let t = player.current {
            VStack(spacing: 0) {
                MiniProgress(clock: player.clock)
                HStack(spacing: 12) {
                    Artwork(url: t.artwork("t120x120"), size: 42)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title ?? "—").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(player.error ?? t.user?.name ?? "")
                            .font(.caption).foregroundColor(player.error == nil ? .secondary : .red).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if player.isBuffering && player.isPlaying {
                        ProgressView().frame(width: 36, height: 36)
                    } else {
                        Button { player.togglePlay() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 36, height: 36)
                        }
                    }
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").font(.title3).frame(width: 36, height: 36)
                    }
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture { player.showFullPlayer = true }
            .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                if v.translation.height < -30 { player.showFullPlayer = true }
                else if v.translation.width < -50 { player.next() }
                else if v.translation.width > 50 { player.previous() }
            })
        }
    }
}

private struct MiniProgress: View {
    @ObservedObject var clock: PlaybackClock
    var body: some View {
        GeometryReader { g in
            Rectangle().fill(Color.accentColor)
                .frame(width: clock.duration > 0 ? g.size.width * min(1, clock.time / clock.duration) : 0)
        }
        .frame(height: 2)
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var downloads: Downloads
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    @State private var artist: SCUser?
    @State private var related: SCTrack?

    var body: some View {
        let t = player.current
        ZStack {
            Artwork(url: t?.artwork(), size: 600, corner: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: 60)
                .opacity(0.55)
                .ignoresSafeArea()
            Color(.systemBackground).opacity(0.35).ignoresSafeArea()

            VStack(spacing: 18) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3.bold()).frame(width: 44, height: 44) }
                    Spacer()
                    if let at = player.sleepAt {
                        Label(at.formatted(date: .omitted, time: .shortened), systemImage: "moon.zzz.fill").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if let t {
                        Menu {
                            TrackMenu(track: t)
                            if let u = t.user { Button { artist = u } label: { Label("К артисту", systemImage: "person") } }
                            Button { related = t } label: { Label("Похожие треки", systemImage: "sparkles") }
                            Menu {
                                ForEach([15, 30, 45, 60, 90], id: \.self) { m in Button("\(m) мин") { player.setSleep(minutes: m) } }
                                if player.sleepAt != nil { Button("Выключить", role: .destructive) { player.setSleep(minutes: nil) } }
                            } label: { Label("Таймер сна", systemImage: "moon.zzz") }
                        } label: { Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44) }
                    }
                }
                .foregroundColor(.primary)

                Spacer(minLength: 0)

                GeometryReader { g in
                    let side = min(g.size.width, g.size.height)
                    Artwork(url: t?.artwork(), size: side, corner: 16)
                        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                        .scaleEffect(player.isPlaying ? 1 : 0.88)
                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: player.isPlaying)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .aspectRatio(1, contentMode: .fit)

                Spacer(minLength: 0)

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t?.title ?? "—").font(.title3.bold()).lineLimit(2)
                        Button { if let u = t?.user { artist = u } } label: {
                            Text(t?.user?.name ?? "").font(.body).foregroundColor(.secondary).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    if let t, session.loggedIn {
                        Button { session.toggleLike(t) } label: {
                            Image(systemName: session.likedIds.contains(t.id) ? "heart.fill" : "heart").font(.title2)
                                .foregroundColor(session.likedIds.contains(t.id) ? .accentColor : .primary)
                        }
                    }
                }

                if let e = player.error {
                    Text(e).font(.footnote).foregroundColor(.red).frame(maxWidth: .infinity, alignment: .leading)
                } else if t?.isSnipped == true {
                    Text("Трек Go+: без подписки играет только превью 30 секунд").font(.footnote).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Scrubber(clock: player.clock) { player.seek(to: $0) }

                HStack {
                    Button { player.toggleShuffle() } label: {
                        Image(systemName: "shuffle").font(.title3).foregroundColor(player.shuffle ? .accentColor : .secondary)
                    }
                    Spacer()
                    Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 30)) }
                    Spacer()
                    Button { player.togglePlay() } label: {
                        ZStack {
                            Circle().fill(Color.primary).frame(width: 74, height: 74)
                            if player.isBuffering && player.isPlaying {
                                ProgressView().tint(Color(.systemBackground))
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 30)).foregroundColor(Color(.systemBackground))
                                    .offset(x: player.isPlaying ? 0 : 2)
                            }
                        }
                    }
                    Spacer()
                    Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 30)) }
                    Spacer()
                    Button { player.cycleRepeat() } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.title3)
                            .foregroundColor(player.repeatMode == .off ? .secondary : .accentColor)
                    }
                }
                .foregroundColor(.primary)

                HStack {
                    RoutePicker().frame(width: 44, height: 44)
                    Spacer()
                    if let t {
                        if downloads.ids.contains(t.id) {
                            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundColor(.accentColor)
                        } else if let p = downloads.progress[t.id] {
                            ProgressView(value: p).progressViewStyle(.circular)
                        } else {
                            Button { downloads.download([t]) } label: { Image(systemName: "arrow.down.circle").font(.title3) }
                        }
                    }
                    Spacer()
                    Button { showQueue = true } label: { Image(systemName: "list.bullet").font(.title3).frame(width: 44, height: 44) }
                }
                .foregroundColor(.primary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showQueue) { QueueView() }
        .sheet(item: $artist) { u in
            NavigationStack { UserView(user: u).tabRoot() }
        }
        .sheet(item: $related) { tr in
            NavigationStack { RelatedView(track: tr).tabRoot() }
        }
    }
}

private struct Scrubber: View {
    @ObservedObject var clock: PlaybackClock
    let onSeek: (Double) -> Void
    @State private var dragging = false
    @State private var value: Double = 0

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { dragging ? value : clock.time }, set: { value = $0 }),
                   in: 0...max(clock.duration, 1)) { editing in
                if editing {
                    value = clock.time
                    dragging = true
                } else {
                    onSeek(value)
                    dragging = false
                }
            }
            HStack {
                Text(formatDuration(dragging ? value : clock.time))
                Spacer()
                Text("-" + formatDuration(max(0, clock.duration - (dragging ? value : clock.time))))
            }
            .font(.caption.monospacedDigit())
            .foregroundColor(.secondary)
        }
    }
}

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        v.tintColor = .label
        v.activeTintColor = .systemOrange
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct QueueView: View {
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let t = player.current {
                    Section("Сейчас играет") {
                        HStack(spacing: 12) {
                            Artwork(url: t.artwork("t120x120"), size: 44)
                            VStack(alignment: .leading) {
                                Text(t.title ?? "—").font(.subheadline.bold()).lineLimit(1)
                                Text(t.user?.name ?? "").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                Section(player.upNext.isEmpty ? "Очередь пуста" : "Далее · \(player.upNext.count)") {
                    ForEach(Array(player.upNext.enumerated()), id: \.offset) { i, t in
                        Button { player.jump(to: player.index + 1 + i) } label: {
                            HStack(spacing: 12) {
                                Artwork(url: t.artwork("t120x120"), size: 40)
                                VStack(alignment: .leading) {
                                    Text(t.title ?? "—").font(.subheadline).foregroundColor(.primary).lineLimit(1)
                                    Text(t.user?.name ?? "").font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    .onDelete { player.removeUpNext(at: $0) }
                    .onMove { player.moveUpNext(from: $0, to: $1) }
                }
            }
            .navigationTitle("Очередь")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
    }
}
