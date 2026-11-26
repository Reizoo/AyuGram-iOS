import SwiftUI
import UIKit

// MARK: navigation

enum Route: Hashable {
    case user(SCUser)
    case playlist(SCPlaylist)
    case related(SCTrack)
    case likes
    case libraryPlaylists
    case feed
    case history
    case downloads
    case charts
}

struct RouteView: View {
    let route: Route
    var body: some View {
        switch route {
        case .user(let u): UserView(user: u)
        case .playlist(let p): PlaylistView(playlist: p)
        case .related(let t): RelatedView(track: t)
        case .likes: LikesView()
        case .libraryPlaylists: LibraryPlaylistsView()
        case .feed: FeedView()
        case .history: HistoryView()
        case .downloads: DownloadsView()
        case .charts: ChartsView()
        }
    }
}

extension View {
    /// Destinations for every tab's navigation stack.
    func tabRoot() -> some View {
        self
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
    }
}

// MARK: paging

@MainActor
final class Pager<T>: ObservableObject {
    @Published private(set) var items: [T] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var loaded = false
    private var next: String?
    private let load: (String?) async throws -> ([T], String?)

    init(_ load: @escaping (String?) async throws -> ([T], String?)) {
        self.load = load
    }

    var hasMore: Bool { next != nil }

    func loadIfNeeded() async {
        if !loaded && !loading { await reload() }
    }

    func reload() async {
        loading = true
        error = nil
        do {
            let (list, n) = try await load(nil)
            items = list
            next = n
            loaded = true
        } catch {
            // A view's task is cancelled when it scrolls away; load again next time instead.
            if !isCancellation(error) {
                self.error = error.localizedDescription
                loaded = true
            }
        }
        loading = false
    }

    func loadMore() async {
        guard !loading, let n = next else { return }
        loading = true
        do {
            let (list, more) = try await load(n)
            items += list
            next = list.isEmpty ? nil : more
        } catch {
            if !isCancellation(error) { self.error = error.localizedDescription }
        }
        loading = false
    }
}

func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let u = error as? URLError, u.code == .cancelled { return true }
    return false
}

/// A list footer that loads the next page when it scrolls into view.
struct LoadMoreFooter<T>: View {
    @ObservedObject var pager: Pager<T>
    var body: some View {
        if pager.hasMore {
            HStack { Spacer(); ProgressView(); Spacer() }
                .listRowSeparator(.hidden)
                .task { await pager.loadMore() }
        } else if let e = pager.error {
            Text(e).font(.footnote).foregroundColor(.secondary).listRowSeparator(.hidden)
        }
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundColor(.secondary)
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center) }
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }
}

// MARK: images

struct Artwork: View {
    let url: URL?
    var size: CGFloat = 52
    var corner: CGFloat = 6
    var circle = false

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.15))) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            default:
                ZStack {
                    LinearGradient(colors: [.orange.opacity(0.5), .pink.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: circle ? "person.fill" : "music.note").foregroundColor(.white.opacity(0.85))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: circle ? size / 2 : corner, style: .continuous))
    }
}

// MARK: rows

struct TrackRow: View {
    let track: SCTrack
    var index: Int? = nil
    let onTap: () -> Void

    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: Downloads
    @EnvironmentObject private var session: Session

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Artwork(url: track.artwork("t120x120"), size: 50)
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45)).frame(width: 50, height: 50)
                        Image(systemName: player.isPlaying ? "waveform" : "pause.fill").foregroundColor(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title ?? "—")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(isCurrent ? .accentColor : .primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if downloads.ids.contains(track.id) {
                            Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundColor(.accentColor)
                        }
                        if track.isSnipped {
                            Text("ПРЕВЬЮ").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().stroke(Color.secondary, lineWidth: 1)).foregroundColor(.secondary)
                        }
                        Text(track.user?.name ?? "").font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let p = downloads.progress[track.id] {
                    ProgressView(value: p).progressViewStyle(.circular).frame(width: 20)
                } else {
                    if session.likedIds.contains(track.id) {
                        Image(systemName: "heart.fill").font(.caption).foregroundColor(.accentColor)
                    }
                    Text(formatDuration(track.seconds)).font(.caption).foregroundColor(.secondary).monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { TrackMenu(track: track) }
        .swipeActions(edge: .leading) {
            Button { player.playNext(track) } label: { Label("Далее", systemImage: "text.insert") }.tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button { player.enqueue([track]) } label: { Label("В очередь", systemImage: "text.append") }.tint(.indigo)
        }
    }
}

struct TrackMenu: View {
    let track: SCTrack
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: Downloads
    @EnvironmentObject private var session: Session

    var body: some View {
        Button { player.playNext(track) } label: { Label("Играть далее", systemImage: "text.insert") }
        Button { player.enqueue([track]) } label: { Label("Добавить в очередь", systemImage: "text.append") }
        Button { player.startStation(track) } label: { Label("Радио по треку", systemImage: "dot.radiowaves.left.and.right") }
        if session.loggedIn {
            Button { session.toggleLike(track) } label: {
                session.likedIds.contains(track.id)
                    ? Label("Убрать лайк", systemImage: "heart.slash")
                    : Label("Лайк", systemImage: "heart")
            }
        }
        if downloads.ids.contains(track.id) {
            Button(role: .destructive) { downloads.remove(track) } label: { Label("Удалить загрузку", systemImage: "trash") }
        } else if downloads.progress[track.id] == nil {
            Button { downloads.download([track]) } label: { Label("Скачать", systemImage: "arrow.down.circle") }
        }
        if let link = track.permalinkUrl {
            Button { UIPasteboard.general.string = link } label: { Label("Скопировать ссылку", systemImage: "link") }
        }
    }
}

struct UserRow: View {
    let user: SCUser
    var body: some View {
        NavigationLink(value: Route.user(user)) {
            HStack(spacing: 12) {
                Artwork(url: user.avatar("t120x120"), size: 50, circle: true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(user.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                        if user.verified == true { Image(systemName: "checkmark.seal.fill").font(.caption).foregroundColor(.accentColor) }
                    }
                    if let f = user.followersCount {
                        Text("\(formatCount(f)) подписчиков").font(.subheadline).foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

struct PlaylistRow: View {
    let playlist: SCPlaylist
    var body: some View {
        NavigationLink(value: Route.playlist(playlist)) {
            HStack(spacing: 12) {
                Artwork(url: playlist.artwork("t120x120"), size: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title ?? "—").font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Text([playlist.user?.name, playlist.trackCount.map { "\($0) треков" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                }
            }
        }
    }
}

struct PlaylistCard: View {
    let playlist: SCPlaylist
    var body: some View {
        NavigationLink(value: Route.playlist(playlist)) {
            VStack(alignment: .leading, spacing: 6) {
                Artwork(url: playlist.artwork("t300x300"), size: 150, corner: 10)
                Text(playlist.title ?? "—").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(playlist.shortDescription ?? playlist.user?.name ?? "").font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            .frame(width: 150)
        }
        .buttonStyle(.plain)
    }
}

/// A list of tracks that plays from the tapped row, with paging.
struct TrackListSection<T>: View {
    @ObservedObject var pager: Pager<T>
    let tracks: (T) -> SCTrack?
    @EnvironmentObject private var player: Player

    var body: some View {
        let list = pager.items.compactMap(tracks)
        ForEach(Array(list.enumerated()), id: \.offset) { i, t in
            TrackRow(track: t) { player.play(list, at: i) }
        }
        LoadMoreFooter(pager: pager)
    }
}

struct PlayShuffleButtons: View {
    let tracks: [SCTrack]
    @EnvironmentObject private var player: Player
    var body: some View {
        HStack(spacing: 12) {
            Button { player.play(tracks) } label: {
                Label("Слушать", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button { player.shufflePlay(tracks) } label: {
                Label("Вперемешку", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .disabled(tracks.isEmpty)
    }
}

// MARK: formatting

func formatDuration(_ s: Double) -> String {
    guard s.isFinite, s > 0 else { return "0:00" }
    let t = Int(s.rounded())
    let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

func formatCount(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
    case 10_000...: return "\(n / 1000)K"
    case 1000...: return String(format: "%.1fK", Double(n) / 1000).replacingOccurrences(of: ".0K", with: "K")
    default: return "\(n)"
    }
}
