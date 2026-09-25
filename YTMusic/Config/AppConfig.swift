import Foundation

/// User-configurable connection settings, persisted in UserDefaults.
///
/// The server runs on the user's own machine (LAN or Tailscale), so the base
/// URL is a setting, not a constant. When the backend is started with
/// `YTM_API_TOKEN`, the same value must be entered here; it is sent as a
/// `Authorization: Bearer` header on every API call and stream request.
@Observable
final class AppConfig {
    private enum Keys {
        static let baseURL = "ytm.serverBaseURL"
        static let apiToken = "ytm.apiToken"
        static let autoDownloadPlaylists = "ytm.autoDownloadPlaylists"
    }

    /// e.g. "http://192.168.1.10:8000" — no trailing slash.
    var serverBaseURLString: String {
        didSet { UserDefaults.standard.set(serverBaseURLString, forKey: Keys.baseURL) }
    }

    /// Optional bearer token (backend `YTM_API_TOKEN`).
    var apiToken: String {
        didSet { UserDefaults.standard.set(apiToken, forKey: Keys.apiToken) }
    }

    /// Playlist IDs with the offline "download all" toggle enabled.
    var autoDownloadPlaylistIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(autoDownloadPlaylistIDs), forKey: Keys.autoDownloadPlaylists)
        }
    }

    init() {
        self.serverBaseURLString = UserDefaults.standard.string(forKey: Keys.baseURL) ?? ""
        self.apiToken = UserDefaults.standard.string(forKey: Keys.apiToken) ?? ""
        let saved = UserDefaults.standard.stringArray(forKey: Keys.autoDownloadPlaylists) ?? []
        self.autoDownloadPlaylistIDs = Set(saved)
    }

    /// Validated base URL, or nil when the user hasn't configured one yet.
    var baseURL: URL? {
        let trimmed = serverBaseURLString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        return URL(string: withScheme)
    }

    var hasToken: Bool { !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Bearer headers applied to API requests and AVPlayer stream requests.
    var authorizationHeaders: [String: String] {
        guard hasToken else { return [:] }
        return ["Authorization": "Bearer \(apiToken.trimmingCharacters(in: .whitespacesAndNewlines))"]
    }
}
