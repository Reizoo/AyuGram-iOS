import SwiftUI

enum SearchScope: String, CaseIterable, Identifiable {
    case tracks = "Треки"
    case users = "Артисты"
    case playlists = "Плейлисты"
    case albums = "Альбомы"
    var id: String { rawValue }
}

struct SearchView: View {
    @State private var query = ""
    @State private var submitted = ""
    @State private var scope: SearchScope = .tracks
    @EnvironmentObject private var recent: SearchHistory

    var body: some View {
        VStack(spacing: 0) {
            if submitted.isEmpty {
                List {
                    if !recent.items.isEmpty {
                        Section {
                            ForEach(recent.items) { RecentRow(item: $0) }
                        } header: {
                            HStack {
                                Text("Недавние").font(.system(size: 17, weight: .bold)).foregroundColor(.white).textCase(nil)
                                Spacer()
                                Button("Очистить") { recent.clear() }.font(.subheadline).textCase(nil)
                            }
                        }
                        .listRowSeparator(.hidden)
                    }
                    if !recent.queries.isEmpty {
                        Section {
                            ForEach(recent.queries, id: \.self) { q in
                                Button {
                                    query = q
                                    submitted = q
                                } label: {
                                    Label(q, systemImage: "magnifyingglass").foregroundColor(.primary)
                                }
                            }
                        } header: {
                            Text("Запросы").font(.system(size: 17, weight: .bold)).foregroundColor(.white).textCase(nil)
                        }
                        .listRowSeparator(.hidden)
                    }
                    Section {
                        NavigationLink(value: Route.charts) { Label("Чарты", systemImage: "chart.line.uptrend.xyaxis") }
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.immediately)
            } else {
                Picker("Где искать", selection: $scope) {
                    ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                SearchResults(query: submitted, scope: scope)
                    .id("\(scope.rawValue)|\(submitted)")
            }
        }
        .navigationTitle("Поиск")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск")
        .autocorrectionDisabled()
        .onSubmit(of: .search) {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            submitted = q
            recent.add(q)
        }
        .task(id: query) {
            // Search as you type, after a pause.
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty {
                submitted = ""
                return
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled, q != submitted { submitted = q }
        }
    }
}

private struct SearchResults: View {
    let query: String
    let scope: SearchScope

    @StateObject private var tracks: Pager<SCTrack>
    @StateObject private var users: Pager<SCUser>
    @StateObject private var playlists: Pager<SCPlaylist>
    @EnvironmentObject private var recent: SearchHistory
    @EnvironmentObject private var player: Player

    init(query: String, scope: SearchScope) {
        self.query = query
        self.scope = scope
        _tracks = StateObject(wrappedValue: Pager { try await SCClient.shared.searchTracks(query, next: $0) })
        _users = StateObject(wrappedValue: Pager { try await SCClient.shared.searchUsers(query, next: $0) })
        _playlists = StateObject(wrappedValue: Pager { try await SCClient.shared.searchPlaylists(query, albums: scope == .albums, next: $0) })
    }

    private var loaded: Bool {
        switch scope {
        case .tracks: return tracks.loaded
        case .users: return users.loaded
        case .playlists, .albums: return playlists.loaded
        }
    }

    private var empty: Bool {
        switch scope {
        case .tracks: return tracks.items.isEmpty
        case .users: return users.items.isEmpty
        case .playlists, .albums: return playlists.items.isEmpty
        }
    }

    private var error: String? {
        switch scope {
        case .tracks: return tracks.error
        case .users: return users.error
        case .playlists, .albums: return playlists.error
        }
    }

    var body: some View {
        List {
            switch scope {
            case .tracks:
                ForEach(Array(tracks.items.enumerated()), id: \.offset) { i, t in
                    TrackRow(track: t) {
                        recent.add(.track(t))
                        player.play(tracks.items, at: i)
                    }
                }
                LoadMoreFooter(pager: tracks)
            case .users:
                ForEach(users.items) { u in
                    UserRow(user: u).simultaneousGesture(TapGesture().onEnded { recent.add(.user(u)) })
                }
                LoadMoreFooter(pager: users)
            case .playlists, .albums:
                ForEach(playlists.items) { p in
                    PlaylistRow(playlist: p).simultaneousGesture(TapGesture().onEnded { recent.add(.playlist(p)) })
                }
                LoadMoreFooter(pager: playlists)
            }
            if loaded && empty {
                EmptyStateView(icon: "magnifyingglass", title: error == nil ? "Ничего не найдено" : "Ошибка", subtitle: error)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .overlay { if !loaded { ProgressView() } }
        .task {
            switch scope {
            case .tracks: await tracks.loadIfNeeded()
            case .users: await users.loadIfNeeded()
            case .playlists, .albums: await playlists.loadIfNeeded()
            }
        }
    }
}

/// A recently opened search result: artwork, title, subtitle and a cross that forgets it.
private struct RecentRow: View {
    let item: RecentItem
    @EnvironmentObject private var recent: SearchHistory
    @EnvironmentObject private var player: Player

    var body: some View {
        HStack(spacing: 14) {
            switch item {
            case .track(let t):
                Button { player.play([t]) } label: {
                    content(url: t.artwork("t120x120"), circle: false, title: t.title ?? "—", subtitle: t.user?.name ?? "")
                }
                .buttonStyle(.plain)
            case .user(let u):
                NavigationLink(value: Route.user(u)) {
                    content(url: u.avatar("t120x120"), circle: true, title: u.name, subtitle: u.followersCount.map { "\(formatCount($0)) подписчиков" } ?? "")
                }
            case .playlist(let p):
                NavigationLink(value: Route.playlist(p)) {
                    content(url: p.artwork("t120x120"), circle: false, title: p.title ?? "—", subtitle: p.user?.name ?? "")
                }
            }
            Button { withAnimation { recent.remove(item) } } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                    .frame(width: 36, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func content(url: URL?, circle: Bool, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Artwork(url: url, size: 52, corner: 4, circle: circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .bold)).foregroundColor(.white).lineLimit(1)
                Text(subtitle).font(.system(size: 15)).foregroundColor(.gray).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
