import SwiftUI
import WebKit

// MARK: playlist

struct PlaylistView: View {
    let playlist: SCPlaylist
    @State private var full: SCPlaylist?
    @State private var tracks: [SCTrack] = []
    @State private var loading = true
    @State private var error: String?
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: Downloads

    private var shown: SCPlaylist { full ?? playlist }

    var body: some View {
        List {
            VStack(spacing: 12) {
                Artwork(url: shown.artwork(), size: 220, corner: 14).shadow(radius: 10, y: 4)
                Text(shown.title ?? "—").font(.title3.bold()).multilineTextAlignment(.center)
                if let u = shown.user, !shown.isSystem {
                    NavigationLink(value: Route.user(u)) { Text(u.name).font(.subheadline).foregroundColor(.accentColor) }
                        .buttonStyle(.plain)
                } else if let d = shown.shortDescription ?? shown.description {
                    Text(d).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center).lineLimit(3)
                }
                Text(summary).font(.caption).foregroundColor(.secondary)
                PlayShuffleButtons(tracks: tracks)
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .padding(.vertical, 8)

            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                TrackRow(track: t) { player.play(tracks, at: i) }
            }

            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
            } else if let error {
                Text(error).font(.footnote).foregroundColor(.secondary).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { player.enqueue(tracks) } label: { Label("Добавить в очередь", systemImage: "text.append") }
                    Button { downloads.download(tracks) } label: { Label("Скачать все", systemImage: "arrow.down.circle") }
                    if let link = shown.permalinkUrl {
                        Button { UIPasteboard.general.string = link } label: { Label("Скопировать ссылку", systemImage: "link") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private var summary: String {
        let count = full?.trackCount ?? (tracks.isEmpty ? playlist.trackCount : tracks.count) ?? 0
        let secs = tracks.reduce(0.0) { $0 + $1.seconds }
        return secs > 0 ? "\(count) треков · \(formatDuration(secs))" : "\(count) треков"
    }

    private func load() async {
        loading = true
        error = nil
        do {
            let p = try await SCClient.shared.playlist(playlist)
            full = p
            let first = (p.tracks ?? []).filter { !$0.isStub }
            if tracks.isEmpty { tracks = first }
            tracks = try await SCClient.shared.fill(p.tracks ?? [])
        } catch {
            if !isCancellation(error) { self.error = error.localizedDescription }
        }
        loading = false
    }
}

// MARK: user

struct UserView: View {
    let user: SCUser

    enum Tab: String, CaseIterable, Identifiable {
        case popular = "Популярное"
        case tracks = "Треки"
        case playlists = "Плейлисты"
        case albums = "Альбомы"
        case likes = "Лайки"
        var id: String { rawValue }
    }

    @State private var full: SCUser?
    @State private var tab: Tab = .popular
    @StateObject private var popular: Pager<SCTrack>
    @StateObject private var tracks: Pager<SCTrack>
    @StateObject private var playlists: Pager<SCPlaylist>
    @StateObject private var albums: Pager<SCPlaylist>
    @StateObject private var likes: Pager<SCTrack>
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player

    init(user: SCUser) {
        self.user = user
        let id = user.id
        _popular = StateObject(wrappedValue: Pager { try await SCClient.shared.userTracks(id, popular: true, next: $0) })
        _tracks = StateObject(wrappedValue: Pager { try await SCClient.shared.userTracks(id, popular: false, next: $0) })
        _playlists = StateObject(wrappedValue: Pager { try await SCClient.shared.userPlaylists(id, albums: false, next: $0) })
        _albums = StateObject(wrappedValue: Pager { try await SCClient.shared.userPlaylists(id, albums: true, next: $0) })
        _likes = StateObject(wrappedValue: Pager { try await SCClient.shared.userLikes(id, next: $0) })
    }

    private var shown: SCUser { full ?? user }

    var body: some View {
        List {
            VStack(spacing: 10) {
                Artwork(url: shown.avatar(), size: 120, circle: true)
                HStack(spacing: 5) {
                    Text(shown.name).font(.title3.bold())
                    if shown.verified == true { Image(systemName: "checkmark.seal.fill").foregroundColor(.accentColor) }
                }
                HStack(spacing: 16) {
                    if let f = shown.followersCount { stat(formatCount(f), "подписчиков") }
                    if let f = shown.followingsCount { stat(formatCount(f), "подписок") }
                    if let t = shown.trackCount { stat(formatCount(t), "треков") }
                }
                if session.loggedIn && session.me?.id != shown.id {
                    let following = session.followingIds.contains(shown.id)
                    Button(following ? "Вы подписаны" : "Подписаться") { session.toggleFollow(shown) }
                        .buttonStyle(.bordered)
                        .tint(following ? Color.secondary : Color.accentColor)
                }
                if let d = shown.description, !d.isEmpty {
                    Text(d).font(.footnote).foregroundColor(.secondary).lineLimit(4).multilineTextAlignment(.center)
                }
                Picker("Раздел", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)

            switch tab {
            case .popular: TrackListSection(pager: popular) { $0 }
            case .tracks: TrackListSection(pager: tracks) { $0 }
            case .likes: TrackListSection(pager: likes) { $0 }
            case .playlists:
                ForEach(playlists.items) { PlaylistRow(playlist: $0) }
                LoadMoreFooter(pager: playlists)
            case .albums:
                ForEach(albums.items) { PlaylistRow(playlist: $0) }
                LoadMoreFooter(pager: albums)
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { player.shufflePlay(tab == .likes ? likes.items : (tab == .tracks ? tracks.items : popular.items)) } label: {
                    Image(systemName: "shuffle")
                }
            }
        }
        .task { full = (try? await SCClient.shared.user(user.id)) ?? full }
        .task(id: tab) {
            switch tab {
            case .popular: await popular.loadIfNeeded()
            case .tracks: await tracks.loadIfNeeded()
            case .playlists: await playlists.loadIfNeeded()
            case .albums: await albums.loadIfNeeded()
            case .likes: await likes.loadIfNeeded()
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.subheadline.bold())
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
    }
}

// MARK: login

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: Session
    @State private var manual = ""
    @State private var showManual = false

    var body: some View {
        NavigationStack {
            LoginWebView { token in
                Task {
                    await session.login(token: token)
                    dismiss()
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Вход в SoundCloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Токен") { showManual = true } }
            }
            .alert("Вход по токену", isPresented: $showManual) {
                TextField("oauth_token", text: $manual)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Войти") {
                    let t = manual.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    Task {
                        await session.login(token: t)
                        dismiss()
                    }
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Значение куки oauth_token с soundcloud.com, если вход на странице не получается.")
            }
        }
    }
}

/// The website's own sign-in. After it succeeds the site sets the `oauth_token` cookie, which is
/// the API token.
struct LoginWebView: UIViewRepresentable {
    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        // Google, Apple and Facebook sign in through a popup window ("Please enable popup windows").
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = SCClient.userAgent
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        cfg.websiteDataStore.httpCookieStore.add(context.coordinator)
        web.load(URLRequest(url: URL(string: "https://soundcloud.com/signin")!))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        let onToken: (String) -> Void
        private var done = false
        private var popups: [WKWebView] = []

        init(onToken: @escaping (String) -> Void) { self.onToken = onToken }

        /// A popup opens over the page in its own web view. It must use the configuration WebKit
        /// passes, so `window.opener` and the sign-in result reach the page.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let host = popups.last ?? webView
            let popup = WKWebView(frame: host.bounds, configuration: configuration)
            popup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            popup.customUserAgent = SCClient.userAgent
            popup.navigationDelegate = self
            popup.uiDelegate = self
            host.addSubview(popup)
            popups.append(popup)
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            webView.removeFromSuperview()
            popups.removeAll { $0 === webView }
            check(webView.configuration.websiteDataStore.httpCookieStore)
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { check(cookieStore) }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            check(webView.configuration.websiteDataStore.httpCookieStore)
        }

        private func check(_ store: WKHTTPCookieStore) {
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.done,
                      let c = cookies.first(where: { $0.name == "oauth_token" && $0.domain.contains("soundcloud.com") && !$0.value.isEmpty })
                else { return }
                self.done = true
                let value = c.value
                DispatchQueue.main.async { self.onToken(value) }
            }
        }
    }
}
