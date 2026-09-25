import Foundation

/// Per-track offline state.
enum DownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case failed(String)
}

/// Manages offline tracks with a background `URLSession` so downloads
/// continue when the app is suspended and finish even if iOS terminates the
/// app (the system relaunches us via the app delegate's
/// `handleEventsForBackgroundURLSession`).
///
/// Singleton: a background session's identifier must map to exactly one
/// `URLSession` per launch, or delegate events are lost.
@Observable
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    /// trackID -> state. Updated on the main actor.
    private(set) var states: [String: DownloadState] = [:]

    private var api: APIClient?
    private var session: URLSession!
    private var backgroundCompletionHandler: (() -> Void)?

    private let sessionIdentifier = "com.ytmusic.downloads"
    private let downloadsDirName = "ytm-downloads"

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.isDiscretionary = false
        // Serial delegate queue; state mutations hop to the main actor.
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        restoreFromDisk()
    }

    func configure(api: APIClient) {
        self.api = api
    }

    // MARK: - Public API

    func state(for trackID: String) -> DownloadState {
        states[trackID] ?? .notDownloaded
    }

    func isDownloaded(trackID: String) -> Bool {
        states[trackID] == .downloaded
    }

    /// Local file URL for a downloaded track, or nil.
    func localFileURL(for trackID: String) -> URL? {
        guard isDownloaded(trackID: trackID) else { return nil }
        let url = downloadsDirectory.appendingPathComponent("\(trackID).m4a")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(_ track: Track) {
        guard let api else { return }
        let current = state(for: track.id)
        if current == .downloaded { return }
        if case .downloading = current { return }
        guard let remote = try? api.streamURL(for: track.id) else {
            setState(.failed("Bad stream URL"), for: track.id)
            return
        }
        var request = URLRequest(url: remote)
        for (field, value) in api.authHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let task = session.downloadTask(with: request)
        task.taskDescription = track.id
        setState(.downloading(progress: 0), for: track.id)
        task.resume()
    }

    func downloadAll(_ tracks: [Track]) {
        for track in tracks { download(track) }
    }

    func deleteDownload(trackID: String) {
        session.getAllTasks { [weak self] tasks in
            tasks.first(where: { $0.taskDescription == trackID })?.cancel()
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.downloadsDirectory.appendingPathComponent("\(trackID).m4a"))
            self.setState(.notDownloaded, for: trackID)
        }
    }

    func deleteAllDownloads() {
        session.getAllTasks { [weak self] tasks in
            tasks.forEach { $0.cancel() }
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.downloadsDirectory)
            try? FileManager.default.createDirectory(at: self.downloadsDirectory, withIntermediateDirectories: true)
            Task { @MainActor in self.states = [:] }
        }
    }

    var totalDownloadedBytes: Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { acc, url in
            acc + (Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
    }

    // MARK: - Background session plumbing

    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == sessionIdentifier else { return }
        backgroundCompletionHandler = completionHandler
    }

    // MARK: - Private

    private var downloadsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(downloadsDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func setState(_ state: DownloadState, for trackID: String) {
        states[trackID] = state
    }

    private func setStateNonIsolated(_ state: DownloadState, for trackID: String) {
        Task { @MainActor in self.states[trackID] = state }
    }

    /// On launch, anything already on disk counts as downloaded.
    private func restoreFromDisk() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory, includingPropertiesForKeys: nil)) ?? []
        var restored: [String: DownloadState] = [:]
        for url in urls where url.pathExtension == "m4a" {
            restored[url.deletingPathExtension().lastPathComponent] = .downloaded
        }
        let captured = restored
        Task { @MainActor in self.states = captured }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let trackID = downloadTask.taskDescription else { return }
        let destination = downloadsDirectory.appendingPathComponent("\(trackID).m4a")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            setStateNonIsolated(.downloaded, for: trackID)
        } catch {
            setStateNonIsolated(.failed(error.localizedDescription), for: trackID)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let trackID = downloadTask.taskDescription,
              totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        setStateNonIsolated(.downloading(progress: progress), for: trackID)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // A download task that finished via didFinishDownloadingTo arrives
        // here with error == nil. Anything else is a real failure — except
        // cancellations, which we treat as "not downloaded".
        guard let trackID = task.taskDescription else { return }
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            // Don't clobber a successful .downloaded state.
            Task { @MainActor [weak self] in
                guard let self, self.states[trackID] != .downloaded else { return }
                self.states[trackID] = .failed(error.localizedDescription)
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // All background work for this launch is done; let the system snapshot.
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        DispatchQueue.main.async { handler?() }
    }
}
