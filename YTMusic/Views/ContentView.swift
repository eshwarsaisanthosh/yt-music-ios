import SwiftUI

/// Root view: tab bar plus a persistent mini-player pinned above it and the
/// full-screen now-playing sheet.
struct ContentView: View {
    @Environment(AppConfig.self) private var config
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player

    @State private var showNowPlaying = false

    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "music.note.list") }
            PlaylistsView()
                .tabItem { Label("Playlists", systemImage: "list.bullet") }
            AddVideoView()
                .tabItem { Label("Add", systemImage: "plus.circle") }
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .safeAreaInset(edge: .bottom) {
            if player.hasQueue, let current = player.current {
                MiniPlayerView(playable: current) { showNowPlaying = true }
                    .padding(.horizontal, 8)
            }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
        .task {
            // First launch with a configured server: pull the library.
            if config.baseURL != nil {
                await library.refresh()
            }
        }
    }
}
