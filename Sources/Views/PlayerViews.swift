import AVKit
import SwiftUI

/// The mini player: a floating rounded bar above the tab bar. The play button carries an orange
/// progress ring; AirPlay and like sit on the right.
struct MiniPlayer: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var session: Session

    var body: some View {
        if let t = player.current {
            HStack(spacing: 12) {
                Button { player.togglePlay() } label: {
                    ZStack {
                        Circle().fill(Color(white: 0.08)).frame(width: 52, height: 52)
                        ProgressRing(clock: player.clock).frame(width: 52, height: 52)
                        Circle().fill(Color.white).frame(width: 40, height: 40)
                        if player.isBuffering && player.isPlaying {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18)).foregroundColor(.black)
                                .offset(x: player.isPlaying ? 0 : 1.5)
                        }
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title ?? "—").font(.system(size: 16, weight: .bold)).foregroundColor(.white).lineLimit(1)
                    Text(player.error ?? t.user?.name ?? "")
                        .font(.system(size: 15)).foregroundColor(player.error == nil ? Color(white: 0.7) : .red).lineLimit(1)
                }
                Spacer(minLength: 0)

                RoutePicker().frame(width: 40, height: 44)
                if session.loggedIn {
                    let liked = session.likedIds.contains(t.id)
                    Button { session.toggleLike(t) } label: {
                        Image(systemName: liked ? "heart.fill" : "heart").font(.system(size: 22))
                            .foregroundColor(liked ? .sc : .white).frame(width: 40, height: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous).fill(Color(white: 0.16).opacity(0.96))
                    .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
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

private struct ProgressRing: View {
    @ObservedObject var clock: PlaybackClock
    var body: some View {
        let f = clock.duration > 0 ? min(1, clock.time / clock.duration) : 0
        Circle()
            .trim(from: 0, to: CGFloat(f))
            .stroke(Color.sc, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .padding(1.5)
    }
}

/// SoundCloud's player: the artwork fills the screen, title and artist sit in black label boxes,
/// and the waveform is the scrubber. Tapping the artwork pauses and resumes.
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
            Color.black.ignoresSafeArea()

            GeometryReader { g in
                AsyncImage(url: t?.artwork("t500x500"), transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    } else {
                        LinearGradient(colors: [Color.sc.opacity(0.6), .black], startPoint: .top, endPoint: .bottom)
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
                .clipped()
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { player.togglePlay() }

            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 180)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom).frame(height: 380)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                header(t)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    if !player.isPlaying && !player.isBuffering {
                        Image(systemName: "play.fill").font(.system(size: 34)).foregroundColor(.white)
                            .frame(width: 84, height: 84).background(Circle().fill(Color.black.opacity(0.55)))
                            .transition(.opacity)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
                Spacer(minLength: 0)

                if let e = player.error {
                    Text(e).font(.footnote).foregroundColor(.red).labelBox().padding(.bottom, 8)
                } else if t?.isSnipped == true {
                    Text("Go+: без подписки играет только превью 30 с").font(.footnote).foregroundColor(.white)
                        .labelBox(Color.sc).padding(.bottom, 8)
                }

                WaveformScrubber(track: t, clock: player.clock) { player.seek(to: $0) }
                    .frame(height: 96)
                    .padding(.bottom, 14)

                controls
                    .padding(.bottom, 18)
                bottomBar(t)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .animation(.easeOut(duration: 0.2), value: player.isPlaying)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showQueue) { QueueView() }
        .sheet(item: $artist) { u in
            NavigationStack { UserView(user: u).tabRoot() }
        }
        .sheet(item: $related) { tr in
            NavigationStack { RelatedView(track: tr).tabRoot() }
        }
    }

    private func header(_ t: SCTrack?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t?.title ?? "—").font(.system(size: 19, weight: .bold)).foregroundColor(.white)
                    .lineLimit(2).labelBox()
                Button { if let u = t?.user { artist = u } } label: {
                    Text(t?.user?.name ?? "").font(.system(size: 15)).foregroundColor(Color(white: 0.75)).lineLimit(1).labelBox()
                }
                .buttonStyle(.plain)
                if let at = player.sleepAt {
                    Label(at.formatted(date: .omitted, time: .shortened), systemImage: "moon.zzz.fill")
                        .font(.caption).foregroundColor(.white).labelBox()
                }
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                    .frame(width: 40, height: 40).background(Circle().fill(Color.black.opacity(0.6)))
            }
        }
        .padding(.top, 8)
    }

    private var controls: some View {
        HStack {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle").font(.system(size: 19)).foregroundColor(player.shuffle ? .sc : .white)
            }
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.system(size: 28)) }
            Spacer()
            Button { player.togglePlay() } label: {
                ZStack {
                    Circle().fill(Color.sc).frame(width: 70, height: 70)
                    if player.isBuffering && player.isPlaying {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28)).offset(x: player.isPlaying ? 0 : 2)
                    }
                }
            }
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 28)) }
            Spacer()
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.system(size: 19))
                    .foregroundColor(player.repeatMode == .off ? .white : .sc)
            }
        }
        .foregroundColor(.white)
    }

    private func bottomBar(_ t: SCTrack?) -> some View {
        HStack(spacing: 0) {
            if let t, session.loggedIn {
                let liked = session.likedIds.contains(t.id)
                Button { session.toggleLike(t) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: liked ? "heart.fill" : "heart").font(.system(size: 20))
                        if let c = t.likesCount, c > 0 { Text(formatCount(c)).font(.caption.bold()) }
                    }
                    .foregroundColor(liked ? .sc : .white)
                    .frame(height: 44)
                }
            } else if let c = t?.likesCount, c > 0 {
                Label(formatCount(c), systemImage: "heart").font(.caption.bold()).foregroundColor(.gray)
            }
            Spacer()
            RoutePicker().frame(width: 44, height: 44)
            Spacer()
            if let t {
                if downloads.ids.contains(t.id) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 20)).foregroundColor(.sc).frame(width: 44, height: 44)
                } else if let p = downloads.progress[t.id] {
                    ProgressView(value: p).progressViewStyle(.circular).tint(.sc).frame(width: 44, height: 44)
                } else {
                    Button { downloads.download([t]) } label: {
                        Image(systemName: "arrow.down.circle").font(.system(size: 20)).frame(width: 44, height: 44)
                    }
                }
            }
            Spacer()
            Button { showQueue = true } label: { Image(systemName: "list.bullet").font(.system(size: 20)).frame(width: 44, height: 44) }
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
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 20)).frame(width: 44, height: 44)
                }
            }
        }
        .foregroundColor(.white)
    }
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        v.tintColor = .white
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
