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
                .tint(.sc)
                .preferredColorScheme(.dark)
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
            tab { FeedTab() }
                .tabItem { Label("Лента", systemImage: "rectangle.stack") }
            tab { SearchView() }
                .tabItem { Label("Поиск", systemImage: "magnifyingglass") }
            tab { LibraryView() }
                .tabItem { Label("Медиатека", systemImage: "books.vertical.fill") }
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

/// SoundCloud keeps the feed in its own tab; without an account it asks to sign in.
struct FeedTab: View {
    @EnvironmentObject private var session: Session
    @State private var showLogin = false

    var body: some View {
        if session.loggedIn {
            FeedView()
        } else {
            VStack(spacing: 16) {
                EmptyStateView(icon: "bolt.horizontal", title: "Лента подписок",
                               subtitle: "Войди, чтобы видеть новые треки и репосты тех, на кого подписан.")
                Button { showLogin = true } label: {
                    Text("Войти").font(.headline).frame(maxWidth: 220).padding(.vertical, 12)
                        .background(Capsule().fill(Color.sc)).foregroundColor(.white)
                }
            }
            .navigationTitle("Лента")
            .sheet(isPresented: $showLogin) { LoginView() }
        }
    }
}
