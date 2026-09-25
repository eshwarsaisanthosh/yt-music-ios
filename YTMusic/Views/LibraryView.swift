import SwiftUI

/// Library tab: all ingested videos.
struct LibraryView: View {
    @Environment(AppConfig.self) private var config
    @Environment(LibraryStore.self) private var library

    var body: some View {
        NavigationStack {
            Group {
                if config.baseURL == nil {
                    ContentUnavailableView(
                        "Server Not Configured",
                        systemImage: "server.rack",
                        description: Text("Open Settings and enter your server address to load your library.")
                    )
                } else if library.isLoading && library.videos.isEmpty {
                    LoadingView()
                } else if library.videos.isEmpty {
                    ContentUnavailableView(
                        "No Music Yet",
                        systemImage: "music.note",
                        description: Text("Use the Add tab to ingest your first YouTube URL.")
                    )
                } else {
                    List(library.videos) { video in
                        NavigationLink(value: video) {
                            HStack(spacing: 12) {
                                ArtworkView(youtubeID: video.youtube_id, size: 52)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(video.title).lineLimit(2)
                                    HStack(spacing: 6) {
                                        Text(video.uploader).lineLimit(1)
                                        Text("·")
                                        Text("\(video.track_count) tracks")
                                        Text("·")
                                        Text(video.formattedDuration)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    if video.needs_review {
                                        Text("Needs review")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.2))
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .refreshable { await library.refresh() }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: Video.self) { video in
                VideoDetailView(video: video)
            }
            if let error = library.lastError {
                ErrorBanner(message: error) {
                    Task { await library.refresh() }
                    library.clearError()
                }
            }
        }
    }
}

/// Video detail: its split tracks, with play-all and per-track actions.
struct VideoDetailView: View {
    let video: Video

    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player

    @State private var detail: Video?
    @State private var isLoading = true

    private var tracks: [Track] { detail?.tracks ?? [] }

    var body: some View {
        Group {
            if isLoading {
                LoadingView()
            } else if tracks.isEmpty {
                ContentUnavailableView(
                    "No Tracks",
                    systemImage: "music.note",
                    description: Text("This video has no playable tracks yet — the ingest job may still be running.")
                )
            } else {
                List {
                    Section {
                        ForEach(playables) { playable in
                            TrackRow(playable: playable)
                                .onTapGesture {
                                    if let index = playables.firstIndex(of: playable) {
                                        player.play(playables, startIndex: index)
                                    }
                                }
                        }
                    } header: {
                        playAllHeader
                    }
                }
            }
        }
        .navigationTitle(video.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var playables: [PlayableTrack] {
        library.playableTracks(tracks, videosByID: [video.id: detail ?? video])
    }

    private var playAllHeader: some View {
        Button {
            player.play(playables)
        } label: {
            Label("Play All (\(tracks.count))", systemImage: "play.fill")
        }
    }

    private func load() async {
        isLoading = true
        detail = await library.videoDetail(id: video.id)
        isLoading = false
    }
}
