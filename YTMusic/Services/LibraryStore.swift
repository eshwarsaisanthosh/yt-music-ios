import Foundation

/// In-memory cache of the server library plus all mutations.
///
/// Views never talk to `APIClient` directly; they go through here so a
/// refresh in one tab is visible everywhere. All state is main-actor bound
/// because it backs SwiftUI views.
@MainActor
@Observable
final class LibraryStore {
    private(set) var videos: [Video] = []
    private(set) var playlists: [Playlist] = []
    private(set) var playlistDetails: [String: Playlist] = [:]
    private(set) var videoDetails: [String: Video] = [:]
    private(set) var isLoading = false
    private(set) var lastError: String?

    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    // MARK: - Reads

    /// Reload videos + playlists concurrently.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let fetchedVideos = api.videos()
            async let fetchedPlaylists = api.playlists()
            let (v, p) = try await (fetchedVideos, fetchedPlaylists)
            videos = v.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            playlists = p
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func playlistDetail(id: String) async -> Playlist? {
        if let cached = playlistDetails[id] { return cached }
        do {
            let full = try await api.playlist(id: id)
            playlistDetails[id] = full
            return full
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    func videoDetail(id: String) async -> Video? {
        if let cached = videoDetails[id] { return cached }
        do {
            let full = try await api.video(id: id)
            videoDetails[id] = full
            return full
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    func search(query: String) async -> SearchResults? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        do {
            return try await api.search(query: trimmed)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    // MARK: - Mutations

    @discardableResult
    func createPlaylist(name: String) async -> Playlist? {
        do {
            let created = try await api.createPlaylist(name: name)
            await refresh()
            return created
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    func renamePlaylist(id: String, name: String) async {
        do {
            _ = try await api.renamePlaylist(id: id, name: name)
            playlistDetails.removeValue(forKey: id)
            await refresh()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func deletePlaylist(id: String) async {
        do {
            try await api.deletePlaylist(id: id)
            playlistDetails.removeValue(forKey: id)
            await refresh()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func addTrack(_ trackID: String, to playlistID: String) async {
        do {
            let updated = try await api.addTrack(playlistID: playlistID, trackID: trackID)
            playlistDetails[playlistID] = updated
            await refresh()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func removeTrack(_ trackID: String, from playlistID: String) async {
        do {
            try await api.removeTrack(playlistID: playlistID, trackID: trackID)
            playlistDetails.removeValue(forKey: playlistID)
            await refresh()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func moveTrack(_ trackID: String, in playlistID: String, to position: Int) async {
        do {
            let updated = try await api.moveTrack(playlistID: playlistID, trackID: trackID, to: position)
            playlistDetails[playlistID] = updated
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func clearError() { lastError = nil }
}

// MARK: - PlayableTrack construction

extension LibraryStore {
    /// Build player-ready tracks. Artwork/artist context comes from the
    /// parent video when available.
    func playableTracks(_ tracks: [Track], videosByID: [String: Video] = [:]) -> [PlayableTrack] {
        tracks.map { track in
            let video = videosByID[track.video_id] ?? videoDetails[track.video_id]
            return PlayableTrack(
                track: track,
                youtubeID: video?.youtube_id ?? "",
                artist: video?.uploader ?? "Unknown artist",
                album: video?.title ?? "Unknown video"
            )
        }
    }

    /// Lookup for resolving track -> video without another network call.
    var videosByID: [String: Video] {
        Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) })
    }
}
