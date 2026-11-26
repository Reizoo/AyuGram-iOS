import SwiftUI

@main
struct NimbusApp: App {
    @StateObject private var player = Player.shared
    @StateObject private var session = Session.shared
    @StateObject private var downloads = Downloads.shared
    @StateObject private var history = History.shared
    @StateObject private var searchHistory = SearchHistory.shared

    init() {
        // Artwork comes through AsyncImage, which uses the shared cache.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(session)
                .environmentObject(downloads)
                .environmentObject(history)
                .environmentObject(searchHistory)
                .tint(.orange)
                .task { await session.refresh() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var downloads: Downloads

    var body: some View {
        TabView {
            tab { HomeView() }
                .tabItem { Label("Главная", systemImage: "house.fill") }
            tab { SearchView() }
                .tabItem { Label("Поиск", systemImage: "magnifyingglass") }
            tab { LibraryView() }
                .tabItem { Label("Медиатека", systemImage: "square.stack.fill") }
        }
        .fullScreenCover(isPresented: $player.showFullPlayer) { NowPlayingView() }
        .alert("SoundCloud", isPresented: Binding(get: { session.message != nil }, set: { if !$0 { session.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.message ?? "")
        }
        .alert("Загрузка", isPresented: Binding(get: { downloads.lastError != nil }, set: { if !$0 { downloads.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloads.lastError ?? "")
        }
    }

    /// Each tab gets its own stack, and the mini player sits above the tab bar in all of them.
    private func tab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content().tabRoot()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayer() }
    }
}
