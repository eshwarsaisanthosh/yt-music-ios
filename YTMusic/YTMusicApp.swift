import SwiftUI

/// Application entry point.
///
/// Wires together the service layer (APIClient, LibraryStore, PlaybackEngine,
/// DownloadManager) and injects them into the view hierarchy via the
/// environment. A UIApplicationDelegate adaptor is required so background
/// download sessions can wake the app when transfers finish.
@main
struct YTMusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var config = AppConfig()
    @State private var apiClient: APIClient
    @State private var library: LibraryStore
    @State private var player: PlaybackEngine
    @State private var downloads: DownloadManager

    init() {
        let config = AppConfig()
        let apiClient = APIClient(config: config)
        _config = State(initialValue: config)
        _apiClient = State(initialValue: apiClient)
        _library = State(initialValue: LibraryStore(api: apiClient))
        _player = State(initialValue: PlaybackEngine(api: apiClient, config: config))
        // DownloadManager is a singleton: the background URLSession must be
        // created exactly once per launch with a stable identifier.
        _downloads = State(initialValue: DownloadManager.shared)
        DownloadManager.shared.configure(api: apiClient)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(config)
                .environment(apiClient)
                .environment(library)
                .environment(player)
                .environment(downloads)
        }
    }
}

/// Minimal app delegate: only exists to receive background URLSession events.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadManager.shared.handleBackgroundEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}
