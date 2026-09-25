import Foundation

// MARK: - Backend models
//
// These Codable structs mirror the FastAPI response schemas in
// yt-music-server/app/api/schemas.py exactly. Keep them in sync if the
// backend changes.

/// An asynchronous ingest job. Poll `GET /v1/jobs/{id}` until `status` is
/// "done" or "failed".
struct Job: Codable, Identifiable {
    let job_id: String
    let video_id: String
    let youtube_id: String
    let status: String
    let stage: String
    let progress: Double
    let attempt: Int
    let max_attempts: Int
    let error_code: String?
    let error_message: String?
    let existing: Bool

    var id: String { job_id }

    var isTerminal: Bool { status == "done" || status == "failed" }
    var isFailed: Bool { status == "failed" }
}

/// One audio track: a chapter split from a video, encoded to ALAC.
struct Track: Codable, Identifiable, Hashable {
    let id: String
    let video_id: String
    let title: String
    let track_no: Int
    let track_total: Int
    let start_s: Double
    let duration_s: Double
    let file_size: Int
    let codec: String
    let sample_rate: Int
    let channels: Int
}

/// A video in the library. `tracks` is only populated on the detail endpoint.
struct Video: Codable, Identifiable, Hashable {
    let id: String
    let youtube_id: String
    let source_url: String
    let title: String
    let uploader: String
    let duration_s: Double
    let needs_review: Bool
    let status: String
    let track_count: Int
    let tracks: [Track]?
}

/// A playlist. `tracks` is only populated on the detail endpoint.
struct Playlist: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let track_count: Int
    let tracks: [Track]?
}

/// `GET /v1/search?q=` response.
struct SearchResults: Codable {
    let tracks: [Track]
    let videos: [Video]
    let playlists: [Playlist]
}

/// `GET /healthz` response (no auth required by the backend).
struct Health: Codable {
    let status: String
    let version: String
    let database: String
    let media_writable: Bool
    let worker_alive: Bool
    let worker_heartbeat_age_s: Double?
}

/// Backend error payload: `{code: "SNAKE_CASE", message: "..."}`.
struct APIErrorPayload: Codable {
    let code: String
    let message: String
}

// MARK: - Client-side models

/// A track paired with everything the player needs to play it: the stream
/// URL (or a local file URL when downloaded) plus artwork context.
struct PlayableTrack: Identifiable, Hashable {
    let track: Track
    /// YouTube video ID, used to build the thumbnail artwork URL.
    let youtubeID: String
    /// Display artist: prefer the video uploader.
    let artist: String
    let album: String

    var id: String { track.id }

    static func == (lhs: PlayableTrack, rhs: PlayableTrack) -> Bool {
        lhs.track.id == rhs.track.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(track.id)
    }
}

extension Track {
    /// Human-readable "3:24" duration.
    var formattedDuration: String {
        let total = Int(duration_s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension Video {
    var formattedDuration: String {
        let total = Int(duration_s.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
