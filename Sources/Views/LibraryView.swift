import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var downloads: Downloads
    @EnvironmentObject private var player: Player
    @State private var showLogin = false
    @State private var confirmLogout = false

    var body: some View {
        List {
            Section {
                if session.loggedIn {
                    HStack(spacing: 14) {
                        Artwork(url: session.me?.avatar("t120x120"), size: 56, circle: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.me?.name ?? "Загрузка…").font(.headline)
                            if let f = session.me?.followersCount {
                                Text("\(formatCount(f)) подписчиков").font(.subheadline).foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        showLogin = true
                    } label: {
                        Label("Войти в SoundCloud", systemImage: "person.crop.circle.badge.plus")
                    }
                    Text("Без входа работают поиск, чарты, плейлисты и загрузки. Вход нужен для лайков, ленты и своих плейлистов.")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }

            Section {
                if session.loggedIn {
                    NavigationLink(value: Route.likes) { Label("Лайки", systemImage: "heart.fill") }
                    NavigationLink(value: Route.libraryPlaylists) { Label("Плейлисты и альбомы", systemImage: "music.note.list") }
                    NavigationLink(value: Route.feed) { Label("Лента", systemImage: "dot.radiowaves.up.forward") }
                    if let me = session.me {
                        NavigationLink(value: Route.user(me)) { Label("Мой профиль", systemImage: "person") }
                    }
                }
                NavigationLink(value: Route.history) { Label("Недавно прослушанные", systemImage: "clock") }
                NavigationLink(value: Route.downloads) {
                    HStack {
                        Label("Загрузки", systemImage: "arrow.down.circle")
                        Spacer()
                        if !downloads.ids.isEmpty { Text("\(downloads.ids.count)").foregroundColor(.secondary) }
                    }
                }
            }

            Section("Воспроизведение") {
                Toggle(isOn: Binding(get: { player.autoplay }, set: { player.autoplay = $0 })) {
                    Label("Автовоспроизведение похожих", systemImage: "infinity")
                }
            }

            if session.loggedIn {
                Section {
                    Button(role: .destructive) { confirmLogout = true } label: { Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right") }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Медиатека")
        .sheet(isPresented: $showLogin) { LoginView() }
        .confirmationDialog("Выйти из аккаунта SoundCloud?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) { session.logout() }
        }
        .refreshable { await session.refresh() }
    }
}

struct LikesView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var downloads: Downloads
    @StateObject private var pager = Pager<SCTrack> { next in
        var uid = await Session.shared.me?.id
        if uid == nil { uid = try await SCClient.shared.me().id }
        guard let id = uid else { throw SCError.notLoggedIn }
        return try await SCClient.shared.userLikes(id, next: next)
    }

    var body: some View {
        List {
            if !pager.items.isEmpty {
                PlayShuffleButtons(tracks: pager.items).listRowSeparator(.hidden)
            }
            TrackListSection(pager: pager) { $0 }
        }
        .listStyle(.plain)
        .navigationTitle("Лайки")
        .overlay { if !pager.loaded { ProgressView() } else if pager.items.isEmpty { EmptyStateView(icon: "heart", title: "Нет лайков", subtitle: pager.error) } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { downloads.download(pager.items) } label: { Label("Скачать загруженные (\(pager.items.count))", systemImage: "arrow.down.circle") }
                    Button { Task { await loadAllAndDownload() } } label: { Label("Скачать все лайки", systemImage: "arrow.down.circle.fill") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .refreshable { await pager.reload() }
        .task { await pager.loadIfNeeded() }
    }

    private func loadAllAndDownload() async {
        var guardCount = 0
        while pager.hasMore && guardCount < 100 {
            await pager.loadMore()
            guardCount += 1
        }
        downloads.download(pager.items)
    }
}

struct LibraryPlaylistsView: View {
    @StateObject private var pager = Pager<SCPlaylist> { next in
        do {
            return try await SCClient.shared.libraryPlaylists(next: next)
        } catch let e as SCError {
            if case .notLoggedIn = e { throw e }
            // Fall back to the account's own playlists.
            guard let id = await Session.shared.me?.id else { throw e }
            return try await SCClient.shared.userPlaylists(id, albums: false, next: next)
        }
    }

    var body: some View {
        List {
            ForEach(pager.items) { PlaylistRow(playlist: $0) }
            LoadMoreFooter(pager: pager)
        }
        .listStyle(.plain)
        .navigationTitle("Плейлисты")
        .overlay { if !pager.loaded { ProgressView() } else if pager.items.isEmpty { EmptyStateView(icon: "music.note.list", title: "Нет плейлистов", subtitle: pager.error) } }
        .refreshable { await pager.reload() }
        .task { await pager.loadIfNeeded() }
    }
}

struct FeedView: View {
    @EnvironmentObject private var player: Player
    @StateObject private var pager = Pager<SCStreamItem> { try await SCClient.shared.feed(next: $0) }

    var body: some View {
        let tracks = pager.items.compactMap { $0.track }
        List {
            ForEach(Array(pager.items.enumerated()), id: \.offset) { _, item in
                if let t = item.track {
                    VStack(alignment: .leading, spacing: 4) {
                        if (item.type ?? "").contains("repost"), let u = item.user {
                            Label("\(u.name) сделал репост", systemImage: "arrow.2.squarepath")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        TrackRow(track: t) {
                            player.play(tracks, at: tracks.firstIndex(where: { $0.id == t.id }) ?? 0)
                        }
                    }
                } else if let p = item.playlist {
                    PlaylistRow(playlist: p)
                }
            }
            LoadMoreFooter(pager: pager)
        }
        .listStyle(.plain)
        .navigationTitle("Лента")
        .overlay { if !pager.loaded { ProgressView() } else if pager.items.isEmpty { EmptyStateView(icon: "dot.radiowaves.up.forward", title: "Лента пуста", subtitle: pager.error) } }
        .refreshable { await pager.reload() }
        .task { await pager.loadIfNeeded() }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var history: History
    @EnvironmentObject private var player: Player
    @State private var server = false
    @StateObject private var pager = Pager<SCTrack> { try await SCClient.shared.history(next: $0) }

    var body: some View {
        List {
            if session.loggedIn {
                Picker("Источник", selection: $server) {
                    Text("Это устройство").tag(false)
                    Text("Аккаунт").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
            }
            if server {
                TrackListSection(pager: pager) { $0 }
            } else {
                ForEach(Array(history.tracks.enumerated()), id: \.offset) { i, t in
                    TrackRow(track: t) { player.play(history.tracks, at: i) }
                }
                if history.tracks.isEmpty {
                    EmptyStateView(icon: "clock", title: "Пока пусто").listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Недавние")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !server && !history.tracks.isEmpty { Button("Очистить") { history.clear() } }
            }
        }
        .task(id: server) { if server { await pager.loadIfNeeded() } }
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var downloads: Downloads
    @EnvironmentObject private var player: Player
    @State private var confirmClear = false

    var body: some View {
        List {
            if !downloads.items.isEmpty {
                PlayShuffleButtons(tracks: downloads.items).listRowSeparator(.hidden)
                Text("\(downloads.items.count) треков · \(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))")
                    .font(.footnote).foregroundColor(.secondary).listRowSeparator(.hidden)
            }
            if !downloads.progress.isEmpty {
                Section("Скачивается: \(downloads.progress.count)") {
                    Button("Отменить очередь") { downloads.cancelPending() }
                }
            }
            ForEach(Array(downloads.items.enumerated()), id: \.element.id) { i, t in
                TrackRow(track: t) { player.play(downloads.items, at: i) }
            }
            .onDelete { idx in
                for i in idx { downloads.remove(downloads.items[i]) }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Загрузки")
        .overlay {
            if downloads.items.isEmpty && downloads.progress.isEmpty {
                EmptyStateView(icon: "arrow.down.circle", title: "Нет загрузок", subtitle: "Скачай трек, плейлист или все лайки, чтобы слушать без интернета.")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !downloads.items.isEmpty {
                    Button(role: .destructive) { confirmClear = true } label: { Image(systemName: "trash") }
                }
            }
        }
        .confirmationDialog("Удалить все загрузки?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Удалить всё", role: .destructive) { downloads.removeAll() }
        }
    }
}

struct RelatedView: View {
    let track: SCTrack
    @StateObject private var pager: Pager<SCTrack>

    init(track: SCTrack) {
        self.track = track
        _pager = StateObject(wrappedValue: Pager { next in
            if next != nil { return ([], nil) }
            return (try await SCClient.shared.related(track.id), nil)
        })
    }

    var body: some View {
        List {
            TrackListSection(pager: pager) { $0 }
        }
        .listStyle(.plain)
        .navigationTitle("Похожие")
        .overlay { if !pager.loaded { ProgressView() } }
        .task { await pager.loadIfNeeded() }
    }
}
