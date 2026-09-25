import SwiftUI

// MARK: - Shared view components

/// YouTube thumbnail artwork with a music-note fallback.
struct ArtworkView: View {
    let youtubeID: String
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            if youtubeID.isEmpty {
                placeholder
            } else {
                AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(youtubeID)/hqdefault.jpg")) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.accentColor.opacity(0.15))
            Image(systemName: "music.note")
                .foregroundStyle(Color.accentColor)
        }
    }
}

/// One track row with playback, download state, and an overflow menu.
struct TrackRow: View {
    let playable: PlayableTrack
    var showDownloadControl = true

    @Environment(DownloadManager.self) private var downloads

    @State private var showPlaylistPicker = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(youtubeID: playable.youtubeID, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(playable.track.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(playable.artist).lineLimit(1)
                    Text("·")
                    Text(playable.track.formattedDuration)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if showDownloadControl {
                downloadButton
            }
            Menu {
                Button("Add to Playlist…") { showPlaylistPicker = true }
                if downloads.isDownloaded(trackID: playable.track.id) {
                    Button("Remove Download", role: .destructive) {
                        downloads.deleteDownload(trackID: playable.track.id)
                    }
                } else {
                    Button("Download") { downloads.download(playable.track) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .contentShape(Rectangle())
        .sheet(isPresented: $showPlaylistPicker) {
            AddToPlaylistSheet(trackID: playable.track.id)
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        switch downloads.state(for: playable.track.id) {
        case .notDownloaded:
            Button { downloads.download(playable.track) } label: {
                Image(systemName: "arrow.down.circle")
            }
        case .downloading(let progress):
            ProgressView(value: progress)
                .frame(width: 24)
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Button { downloads.download(playable.track) } label: {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
            }
        }
    }
}

/// Sheet listing playlists to add a track to.
struct AddToPlaylistSheet: View {
    let trackID: String
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var newPlaylistName = ""
    @State private var showNewPlaylistField = false

    var body: some View {
        NavigationStack {
            List {
                if showNewPlaylistField {
                    HStack {
                        TextField("Playlist name", text: $newPlaylistName)
                        Button("Create") {
                            Task {
                                if let created = await library.createPlaylist(name: newPlaylistName),
                                   !newPlaylistName.isEmpty {
                                    await library.addTrack(trackID, to: created.id)
                                }
                                dismiss()
                            }
                        }
                        .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    Button("New Playlist…") { showNewPlaylistField = true }
                }
                ForEach(library.playlists) { playlist in
                    Button(playlist.name) {
                        Task {
                            await library.addTrack(trackID, to: playlist.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Full-screen loading / error / empty states.
struct LoadingView: View {
    var body: some View {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorBanner: View {
    let message: String
    var onRetry: (() -> Void)?

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(message).font(.caption).lineLimit(2)
            Spacer()
            if let onRetry {
                Button("Retry", action: onRetry).font(.caption)
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
    }
}
