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
                    if !recent.queries.isEmpty {
                        Section {
                            ForEach(recent.queries, id: \.self) { q in
                                Button {
                                    query = q
                                    submitted = q
                                } label: {
                                    Label(q, systemImage: "clock.arrow.circlepath").foregroundColor(.primary)
                                }
                            }
                        } header: {
                            HStack {
                                Text("Недавние")
                                Spacer()
                                Button("Очистить") { recent.clear() }.font(.caption)
                            }
                        }
                    }
                    Section("Обзор") {
                        NavigationLink(value: Route.charts) { Label("Чарты", systemImage: "chart.line.uptrend.xyaxis") }
                    }
                }
                .listStyle(.insetGrouped)
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
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Треки, артисты, плейлисты")
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
                TrackListSection(pager: tracks) { $0 }
            case .users:
                ForEach(users.items) { UserRow(user: $0) }
                LoadMoreFooter(pager: users)
            case .playlists, .albums:
                ForEach(playlists.items) { PlaylistRow(playlist: $0) }
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
