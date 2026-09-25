import SwiftUI

/// Search tab: debounced substring search across tracks, videos, playlists.
struct SearchView: View {
    @Environment(AppConfig.self) private var config
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player

    @State private var query = ""
    @State private var results: SearchResults?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if config.baseURL == nil {
                    ContentUnavailableView(
                        "Server Not Configured",
                        systemImage: "server.rack",
                        description: Text("Open Settings and enter your server address.")
                    )
                } else if let results {
                    resultsList(results)
                } else {
                    ContentUnavailableView(
                        "Search Your Library",
                        systemImage: "magnifyingglass",
                        description: Text("Find tracks, videos, and playlists.")
                    )
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Tracks, videos, playlists")
            .onChange(of: query) { _, newValue in
                scheduleSearch(for: newValue)
            }
            .overlay(alignment: .center) {
                if isSearching { ProgressView() }
            }
        }
    }

    private func scheduleSearch(for text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = nil
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let found = await library.search(query: trimmed)
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }

    private func resultsList(_ results: SearchResults) -> some View {
        let playables = library.playableTracks(results.tracks)
        return List {
            if !results.tracks.isEmpty {
                Section("Tracks") {
                    ForEach(playables) { playable in
                        TrackRow(playable: playable)
                            .onTapGesture {
                                if let index = playables.firstIndex(of: playable) {
                                    player.play(playables, startIndex: index)
                                }
                            }
                    }
                }
            }
            if !results.videos.isEmpty {
                Section("Videos") {
                    ForEach(results.videos) { video in
                        NavigationLink(value: video) {
                            HStack {
                                ArtworkView(youtubeID: video.youtube_id, size: 44)
                                VStack(alignment: .leading) {
                                    Text(video.title).lineLimit(1)
                                    Text("\(video.track_count) tracks · \(video.uploader)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            if !results.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(results.playlists) { playlist in
                        NavigationLink(value: playlist) {
                            Text(playlist.name)
                        }
                    }
                }
            }
        }
        .navigationDestination(for: Video.self) { video in
            VideoDetailView(video: video)
        }
        .navigationDestination(for: Playlist.self) { playlist in
            PlaylistDetailView(playlist: playlist)
        }
    }
}
