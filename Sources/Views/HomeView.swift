import SwiftUI

@MainActor
final class HomeModel: ObservableObject {
    @Published var selections: [SCSelection] = []
    @Published var trending: [SCTrack] = []
    @Published var error: String?
    @Published var loading = false
    private var loadedFor: Bool?

    func load(loggedIn: Bool, force: Bool = false) async {
        if !force, loadedFor == loggedIn, !selections.isEmpty { return }
        loading = true
        error = nil
        do {
            async let sel = SCClient.shared.selections()
            async let top = SCClient.shared.charts(kind: "trending", genre: "soundcloud:genres:all-music", next: nil)
            let s = try await sel
            selections = s.filter { !($0.items?.collection.isEmpty ?? true) }
            trending = (try? await top)?.0 ?? []
            loadedFor = loggedIn
        } catch {
            if !isCancellation(error) { self.error = error.localizedDescription }
        }
        loading = false
    }
}

struct HomeView: View {
    @StateObject private var model = HomeModel()
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if session.loggedIn {
                    HStack(spacing: 10) {
                        QuickTile(title: "Лента", icon: "dot.radiowaves.up.forward", route: .feed)
                        QuickTile(title: "Лайки", icon: "heart.fill", route: .likes)
                    }
                    .padding(.horizontal)
                }

                if !model.trending.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        NavigationLink(value: Route.charts) {
                            HStack {
                                Text("В тренде").font(.title3.bold())
                                Image(systemName: "chevron.right").font(.subheadline.bold()).foregroundColor(.secondary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHGrid(rows: Array(repeating: GridItem(.fixed(58), spacing: 6), count: 4), spacing: 16) {
                                ForEach(Array(model.trending.prefix(24).enumerated()), id: \.offset) { i, t in
                                    CompactTrack(track: t) { player.play(model.trending, at: i) }
                                        .frame(width: 300)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }

                ForEach(model.selections, id: \.key) { sel in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(sel.title ?? "").font(.title3.bold()).padding(.horizontal)
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
            .padding(.vertical)
        }
        .navigationTitle("Главная")
        .refreshable { await model.load(loggedIn: session.loggedIn, force: true) }
        .task(id: session.loggedIn) { await model.load(loggedIn: session.loggedIn) }
    }
}

struct QuickTile: View {
    let title: String
    let icon: String
    let route: Route
    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.headline).foregroundColor(.accentColor)
                Text(title).font(.subheadline.bold())
                Spacer()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
    }
}

struct CompactTrack: View {
    let track: SCTrack
    let onTap: () -> Void
    @EnvironmentObject private var player: Player

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Artwork(url: track.artwork("t120x120"), size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title ?? "—").font(.system(size: 14, weight: .medium))
                        .foregroundColor(player.current?.id == track.id ? .accentColor : .primary).lineLimit(1)
                    Text(track.user?.name ?? "").font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { TrackMenu(track: track) }
    }
}

struct ChartsView: View {
    private static let genres: [(String, String)] = [
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
