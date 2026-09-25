import Foundation

/// Errors surfaced from the backend API.
enum APIError: LocalizedError {
    case notConfigured
    case invalidURL
    case http(status: Int, code: String?, message: String?)
    case decoding(Error)
    case network(URLError)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Server URL is not set. Open Settings and enter your server address."
        case .invalidURL:
            return "The server URL looks invalid."
        case .http(let status, let code, let message):
            if status == 401 { return "Unauthorized — check the API token in Settings." }
            if let message, !message.isEmpty { return message }
            if let code { return "Server error (\(code))." }
            return "Server returned HTTP \(status)."
        case .decoding:
            return "Couldn't understand the server response."
        case .network(let urlError):
            return urlError.localizedDescription
        }
    }
}

/// Thin async/await wrapper over the yt-music-server `/v1` REST API.
///
/// Every method throws `APIError`. Auth is injected from `AppConfig` when a
/// token is configured. No state is cached here — caching lives in
/// `LibraryStore`.
final class APIClient {
    private let config: AppConfig
    private let session: URLSession
    private let decoder: JSONDecoder

    init(config: AppConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
        self.decoder = JSONDecoder()
    }

    // MARK: - URL building

    private func url(for path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let base = config.baseURL else { throw APIError.notConfigured }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw APIError.invalidURL }
        return url
    }

    /// Direct stream URL for AVPlayer. Auth headers cannot be attached to a
    /// plain URL — `PlaybackEngine` uses `AVURLAssetHTTPHeaderFieldsKey`
    /// instead (see `authorizedStreamURLRequest(for:)`).
    func streamURL(for trackID: String) throws -> URL {
        try url(for: "v1/tracks/\(trackID)/stream")
    }

    /// Bearer headers for requests that can't go through `request(_:)`
    /// (AVPlayer asset options, background download tasks).
    var authHeaders: [String: String] { config.authorizationHeaders }

    // MARK: - Request plumbing

    private func request(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Encodable? = nil
    ) throws -> URLRequest {
        var req = URLRequest(url: try url(for: path, query: query))
        req.httpMethod = method
        for (field, value) in config.authorizationHeaders {
            req.setValue(value, forHTTPHeaderField: field)
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        return req
    }

    private struct EmptyBody: Encodable {}

    private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlError as URLError {
            throw APIError.network(urlError)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(status: -1, code: nil, message: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = try? decoder.decode(APIErrorPayload.self, from: data)
            throw APIError.http(status: http.statusCode, code: payload?.code, message: payload?.message)
        }
        // 204 No Content carries no body.
        if http.statusCode == 204, T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    private func send(_ req: URLRequest) async throws {
        let _: EmptyResponse = try await send(req, as: EmptyResponse.self)
    }

    // MARK: - Ingest & jobs

    struct IngestBody: Encodable {
        let url: String
        let playlist_id: String?
    }

    func ingest(url: String, playlistID: String? = nil) async throws -> Job {
        let req = try request("POST", "v1/ingest", body: IngestBody(url: url, playlist_id: playlistID))
        return try await send(req, as: Job.self)
    }

    func job(id: String) async throws -> Job {
        let req = try request("GET", "v1/jobs/\(id)")
        return try await send(req, as: Job.self)
    }

    // MARK: - Library

    func videos() async throws -> [Video] {
        let req = try request("GET", "v1/videos")
        return try await send(req, as: [Video].self)
    }

    func video(id: String) async throws -> Video {
        let req = try request("GET", "v1/videos/\(id)")
        return try await send(req, as: Video.self)
    }

    func search(query: String) async throws -> SearchResults {
        let req = try request("GET", "v1/search", query: [URLQueryItem(name: "q", value: query)])
        return try await send(req, as: SearchResults.self)
    }

    func health() async throws -> Health {
        let req = try request("GET", "healthz")
        return try await send(req, as: Health.self)
    }

    // MARK: - Playlists

    struct PlaylistNameBody: Encodable { let name: String }
    struct AddTrackBody: Encodable {
        let track_id: String
        let position: Int?
    }

    func playlists() async throws -> [Playlist] {
        let req = try request("GET", "v1/playlists")
        return try await send(req, as: [Playlist].self)
    }

    func createPlaylist(name: String) async throws -> Playlist {
        let req = try request("POST", "v1/playlists", body: PlaylistNameBody(name: name))
        return try await send(req, as: Playlist.self)
    }

    func playlist(id: String) async throws -> Playlist {
        let req = try request("GET", "v1/playlists/\(id)")
        return try await send(req, as: Playlist.self)
    }

    func renamePlaylist(id: String, name: String) async throws -> Playlist {
        let req = try request("PATCH", "v1/playlists/\(id)", body: PlaylistNameBody(name: name))
        return try await send(req, as: Playlist.self)
    }

    func deletePlaylist(id: String) async throws {
        let req = try request("DELETE", "v1/playlists/\(id)")
        try await send(req)
    }

    func addTrack(playlistID: String, trackID: String, position: Int? = nil) async throws -> Playlist {
        let req = try request("POST", "v1/playlists/\(playlistID)/tracks",
                              body: AddTrackBody(track_id: trackID, position: position))
        return try await send(req, as: Playlist.self)
    }

    func removeTrack(playlistID: String, trackID: String) async throws {
        let req = try request("DELETE", "v1/playlists/\(playlistID)/tracks/\(trackID)")
        try await send(req)
    }

    /// The backend has no reorder endpoint; a move is delete + re-insert at
    /// the target position (the backend compacts positions on delete).
    func moveTrack(playlistID: String, trackID: String, to position: Int) async throws -> Playlist {
        try await removeTrack(playlistID: playlistID, trackID: trackID)
        return try await addTrack(playlistID: playlistID, trackID: trackID, position: position)
    }
}

/// Marker type for 204 No Content responses.
private struct EmptyResponse: Decodable {}
