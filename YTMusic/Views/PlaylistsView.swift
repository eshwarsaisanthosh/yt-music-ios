import SwiftUI

/// Playlists tab: list, create, rename, delete.
struct PlaylistsView: View {
    @Environment(AppConfig.self) private var config
    @Environment(LibraryStore.self) private var library

    @State private var showCreateAlert = false
    @State private var newName = ""
    @State private var renaming: Playlist?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            Group {
                if config.baseURL == nil {
                    ContentUnavailableView(
                        "Server Not Configured",
                        systemImage: "server.rack",
                        description: Text("Open Settings and enter your server address.")
                    )
                } else if library.playlists.isEmpty && !library.isLoading {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "list.bullet",
                        description: Text("Create a playlist, or add a video and pick a playlist during ingest.")
                    )
                } else {
                    List {
                        ForEach(library.playlists) { playlist in
                            NavigationLink(value: playlist) {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(playlist.name)
                                        Text("\(playlist.track_count) tracks")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "music.note.list")
                                }
                            }
                        }
                        .onDelete(perform: delete)
                    }
                    .refreshable { await library.refresh() }
                }
            }
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showCreateAlert = true } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(config.baseURL == nil)
                }
            }
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
            }
            .alert("New Playlist", isPresented: $showCreateAlert) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) { newName = "" }
                Button("Create") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    newName = ""
                    if !name.isEmpty {
                        Task { await library.createPlaylist(name: name) }
                    }
                }
            }
            .alert("Rename Playlist", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    if let renaming {
                        Task { await library.renamePlaylist(id: renaming.id, name: renameText) }
                    }
                }
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let playlist = library.playlists[index]
            Task { await library.deletePlaylist(id: playlist.id) }
        }
    }
}

/// Playlist detail: ordered tracks with play, reorder, remove, and the
/// per-playlist offline toggle.
struct PlaylistDetailView: View {
    let playlist: Playlist

    @Environment(AppConfig.self) private var config
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads

    @State private var detail: Playlist?
    @State private var isLoading = true
    @State private var editMode: EditMode = .inactive

    private var tracks: [Track] { detail?.tracks ?? [] }

    var body: some View {
        Group {
            if isLoading {
                LoadingView()
            } else if tracks.isEmpty {
                ContentUnavailableView(
                    "Empty Playlist",
                    systemImage: "list.bullet",
                    description: Text("Add tracks from the Library or during ingest.")
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
                        .onDelete(perform: remove)
                        .onMove(perform: move)
                    } header: {
                        Button {
                            player.play(playables)
                        } label: {
                            Label("Play All (\(tracks.count))", systemImage: "play.fill")
                        }
                    }

                    Section("Offline") {
                        Toggle("Download for offline", isOn: offlineBinding)
                        let downloaded = tracks.filter { downloads.isDownloaded(trackID: $0.id) }.count
                        HStack {
                            Text("Downloaded")
                            Spacer()
                            Text("\(downloaded) / \(tracks.count)")
                                .foregroundStyle(.secondary)
                        }
                        Button("Remove All Downloads", role: .destructive) {
                            for track in tracks {
                                downloads.deleteDownload(trackID: track.id)
                            }
                            config.autoDownloadPlaylistIDs.remove(playlist.id)
                        }
                    }
                }
                .environment(\.editMode, $editMode)
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
        .task { await load() }
        .onChange(of: detail?.tracks) { _, newTracks in
            // Honor the offline toggle for newly added tracks.
            if config.autoDownloadPlaylistIDs.contains(playlist.id),
               let newTracks {
                downloads.downloadAll(newTracks)
            }
        }
    }

    private var playables: [PlayableTrack] {
        library.playableTracks(tracks)
    }

    private var offlineBinding: Binding<Bool> {
        Binding(
            get: { config.autoDownloadPlaylistIDs.contains(playlist.id) },
            set: { enabled in
                if enabled {
                    config.autoDownloadPlaylistIDs.insert(playlist.id)
                    downloads.downloadAll(tracks)
                } else {
                    config.autoDownloadPlaylistIDs.remove(playlist.id)
                }
            }
        )
    }

    private func load() async {
        isLoading = true
        detail = await library.playlistDetail(id: playlist.id)
        isLoading = false
    }

    private func remove(at offsets: IndexSet) {
        let current = tracks
        for index in offsets {
            let track = current[index]
            Task { await library.removeTrack(track.id, from: playlist.id) }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        // Backend has no reorder endpoint: move = delete + re-insert.
        // Handle single-item moves (the common case from the UI).
        guard let from = source.first else { return }
        let current = tracks
        guard current.indices.contains(from) else { return }
        let trackID = current[from].id
        var adjusted = destination
        if destination > from { adjusted -= 1 }
        Task {
            detail = await library.moveTrackAndReturn(trackID, in: playlist.id, to: adjusted)
        }
    }
}

// Helper so the detail view can refresh its local copy after a move.
extension LibraryStore {
    func moveTrackAndReturn(_ trackID: String, in playlistID: String, to position: Int) async -> Playlist? {
        await moveTrack(trackID, in: playlistID, to: position)
        return playlistDetails[playlistID]
    }
}
