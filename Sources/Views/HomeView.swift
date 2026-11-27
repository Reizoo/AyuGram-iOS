import SwiftUI

@MainActor
final class HomeModel: ObservableObject {
    @Published var selections: [SCSelection] = []
    @Published var trending: [SCTrack] = []
    @Published var genre = "all-music"
    @Published var error: String?
    @Published var loading = false
    private var loadedFor: Bool?

    func load(loggedIn: Bool, force: Bool = false) async {
        if !force, loadedFor == loggedIn, !selections.isEmpty { return }
        loading = true
        error = nil
        do {
            async let top: Void = loadTrending()
            let s = try await SCClient.shared.selections()
            selections = s.filter { !($0.items?.collection.isEmpty ?? true) }
            _ = await top
            loadedFor = loggedIn
        } catch {
            if !isCancellation(error) { self.error = error.localizedDescription }
        }
        loading = false
    }

    func loadTrending() async {
        let g = genre
        let list = (try? await SCClient.shared.charts(kind: "trending", genre: "soundcloud:genres:\(g)", next: nil))?.0
        if g == genre, let list { trending = list }
    }
}

struct HomeView: View {
    @StateObject private var model = HomeModel()
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var history: History

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                if session.loggedIn || !history.tracks.isEmpty {
                    VStack(spacing: 10) {
                        if session.loggedIn { LikesBanner().padding(.horizontal) }
                        if !history.tracks.isEmpty {
                            let recent = Array(history.tracks.prefix(4))
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                                ForEach(Array(recent.enumerated()), id: \.offset) { i, t in
                                    RecentTile(track: t) { player.play(history.tracks, at: i) }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }

                ForEach(model.selections, id: \.key) { sel in
                    VStack(alignment: .leading, spacing: 14) {
                        SectionTitle(text: sel.title ?? "", subtitle: sel.description)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(sel.items?.collection ?? []) { p in
                                    PlaylistCard(playlist: p)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }

                trendingSection

                if model.loading && model.selections.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 60)
                }
                if let e = model.error, model.selections.isEmpty {
                    VStack(spacing: 12) {
                        EmptyStateView(icon: "wifi.exclamationmark", title: "Не загрузилось", subtitle: e)
                        Button("Повторить") { Task { await model.load(loggedIn: session.loggedIn, force: true) } }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if let me = session.me {
                    NavigationLink(value: Route.user(me)) {
                        Artwork(url: me.avatar("t120x120"), size: 34, circle: true)
                    }
                } else {
                    Text("Nimbus").font(.system(size: 22, weight: .heavy))
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink(value: Route.history) { Image(systemName: "clock.arrow.circlepath").font(.system(size: 18)) }
                    .foregroundColor(.primary)
            }
        }
        .refreshable { await model.load(loggedIn: session.loggedIn, force: true) }
        .task(id: session.loggedIn) { await model.load(loggedIn: session.loggedIn) }
    }

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink(value: Route.charts) {
                HStack(spacing: 6) {
                    Text("В тренде по жанрам").font(.system(size: 24, weight: .bold))
                    Image(systemName: "chevron.right").font(.subheadline.bold()).foregroundColor(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ChartsView.genres.indices, id: \.self) { i in
                        let g = ChartsView.genres[i]
                        GenreChip(title: g.0, selected: model.genre == g.1) {
                            guard model.genre != g.1 else { return }
                            model.genre = g.1
                            model.trending = []
                            Task { await model.loadTrending() }
                        }
                    }
                }
                .padding(.horizontal)
            }

            if model.trending.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.frame(height: 3 * 72)
            } else {
                GeometryReader { g in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(rows: Array(repeating: GridItem(.fixed(64), spacing: 8), count: 3), spacing: 12) {
                            ForEach(Array(model.trending.prefix(30).enumerated()), id: \.offset) { i, t in
                                ChartRow(track: t) { player.play(model.trending, at: i) }
                                    .frame(width: g.size.width * 0.86)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .frame(height: 3 * 64 + 2 * 8)
            }
        }
    }
}

/// "Your likes": opens the likes, and the round button shuffles them.
struct LikesBanner: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var session: Session
    @State private var busy = false

    var body: some View {
        ZStack(alignment: .leading) {
            NavigationLink(value: Route.likes) {
                HStack(spacing: 0) {
                    HeartStack().frame(width: 120, height: 66).clipped()
                    Text("Твои лайки").font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                        .padding(.leading, -18)
                    Spacer()
                }
                .frame(height: 66)
                .background(
                    LinearGradient(colors: [Color(red: 0.42, green: 0.17, blue: 0.06), Color(white: 0.17)],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack {
                Spacer()
                Button { Task { await shuffle() } } label: {
                    ZStack {
                        Circle().fill(Color.black.opacity(0.85)).frame(width: 46, height: 46)
                        if busy { ProgressView().tint(.white) } else {
                            Image(systemName: "shuffle").font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
            }
        }
    }

    private func shuffle() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        var uid = session.me?.id
        if uid == nil { uid = try? await SCClient.shared.me().id }
        guard let id = uid, let page = try? await SCClient.shared.userLikes(id, next: nil) else { return }
        player.shufflePlay(page.0)
    }
}

/// Outlined hearts fanned out to the left, in orange.
private struct HeartStack: View {
    var body: some View {
        ZStack {
            ForEach(0..<5) { i in
                Image(systemName: "heart")
                    .font(.system(size: 64, weight: .light))
                    .foregroundColor(Color.sc.opacity(1 - Double(i) * 0.15))
                    .offset(x: CGFloat(-i) * 5 - 8, y: CGFloat(i) * 4 + 6)
            }
            Image(systemName: "heart.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundColor(Color(red: 0.12, green: 0.05, blue: 0.03))
                .offset(x: 0, y: 2)
            Image(systemName: "heart")
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.sc)
                .offset(x: 0, y: 2)
        }
    }
}

/// A recently played track as a dark tile, two per row.
struct RecentTile: View {
    let track: SCTrack
    let onTap: () -> Void
    @EnvironmentObject private var player: Player

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Artwork(url: track.artwork("t120x120"), size: 44, corner: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title ?? "—").font(.system(size: 15, weight: .bold))
                        .foregroundColor(player.current?.id == track.id ? .sc : .white).lineLimit(1)
                    Text(track.user?.name ?? "").font(.system(size: 14)).foregroundColor(.gray).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(white: 0.14)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { TrackMenu(track: track) }
    }
}

struct GenreChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    private static let blue = Color(red: 0.38, green: 0.6, blue: 1)

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .tracking(0.6)
                .foregroundColor(selected ? Self.blue : .white)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .overlay(Capsule().stroke(selected ? Self.blue : Color.white.opacity(0.35), lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A chart track: artwork, bold title, artist with a liked heart, and the "…" menu.
struct ChartRow: View {
    let track: SCTrack
    let onTap: () -> Void
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var session: Session

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    Artwork(url: track.artwork("t120x120"), size: 58, corner: 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title ?? "—").font(.system(size: 16, weight: .bold))
                            .foregroundColor(player.current?.id == track.id ? .sc : .white).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(track.user?.name ?? "").lineLimit(1)
                            if session.likedIds.contains(track.id) {
                                Text("·")
                                Image(systemName: "heart.fill").foregroundColor(.sc)
                            }
                        }
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu { TrackMenu(track: track) } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                    .frame(width: 36, height: 44).contentShape(Rectangle())
            }
        }
    }
}

struct ChartsView: View {
    static let genres: [(String, String)] = [
        ("Вся музыка", "all-music"), ("Хип-хоп", "hiphoprap"), ("Электроника", "electronic"), ("Хаус", "house"),
        ("Поп", "pop"), ("R&B", "rbsoul"), ("Рок", "rock"), ("Техно", "techno"), ("Трэп", "trap"),
        ("Драм-н-бейс", "drumbass"), ("Дабстеп", "dubstep"), ("Эмбиент", "ambient"), ("Инди", "indie"),
        ("Латино", "latin"), ("Регги", "reggaeton"), ("Танцевальная", "danceedm"), ("Дип-хаус", "deephouse"),
        ("Фолк", "folksingersongwriter"), ("Джаз", "jazzblues"), ("Классика", "classical"),
    ]

    @State private var genre = "all-music"
    @State private var top = false

    var body: some View {
        ChartList(kind: top ? "top" : "trending", genre: genre)
            .id("\(top)-\(genre)")
            .navigationTitle(top ? "Топ 50" : "В тренде")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Чарт", selection: $top) {
                            Text("В тренде").tag(false)
                            Text("Топ 50").tag(true)
                        }
                        Picker("Жанр", selection: $genre) {
                            ForEach(Self.genres.indices, id: \.self) { i in Text(Self.genres[i].0).tag(Self.genres[i].1) }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
    }
}

private struct ChartList: View {
    @StateObject private var pager: Pager<SCTrack>

    init(kind: String, genre: String) {
        _pager = StateObject(wrappedValue: Pager { next in
            try await SCClient.shared.charts(kind: kind, genre: "soundcloud:genres:\(genre)", next: next)
        })
    }

    var body: some View {
        List {
            TrackListSection(pager: pager) { $0 }
            if pager.loaded && pager.items.isEmpty && pager.error == nil {
                EmptyStateView(icon: "chart.bar", title: "Пусто")
            }
        }
        .listStyle(.plain)
        .overlay { if !pager.loaded { ProgressView() } }
        .refreshable { await pager.reload() }
        .task { await pager.loadIfNeeded() }
    }
}
