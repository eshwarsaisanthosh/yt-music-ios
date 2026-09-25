import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// Repeat behaviour for the queue.
enum RepeatMode: String, CaseIterable {
    case off, all, one
}

/// Owns the `AVQueuePlayer`, the play queue, lock-screen / Control Center
/// integration, and audio-session policy (interruptions, route changes).
///
/// Queue model: `queue` is the full ordered track list; `playOrder` is a
/// permutation of indices into `queue` (identity when shuffle is off);
/// `position` is the index into `playOrder` of the current track.
/// `AVQueuePlayer` is (re)built from `playOrder[position...]` on every
/// navigation so next/previous/shuffle stay exact.
///
/// Concurrency: the class is `@MainActor`. AVFoundation callbacks (KVO,
/// notifications, time observers, remote-command handlers) are nonisolated
/// even when queued on the main thread, so every one of them hops back via
/// `Task { @MainActor in … }`.
@MainActor
@Observable
final class PlaybackEngine: NSObject {
    // MARK: - Observable state

    private(set) var current: PlayableTrack?
    private(set) var isPlaying = false
    private(set) var progress: Double = 0        // 0...1 within current track
    private(set) var elapsed: Double = 0         // seconds
    private(set) var duration: Double = 0        // seconds
    private(set) var hasQueue = false
    var shuffle = false { didSet { reshufflePreservingCurrent() } }
    var repeatMode: RepeatMode = .off { didSet { updateActionAtItemEnd() } }

    // MARK: - Dependencies

    private let api: APIClient
    private let config: AppConfig
    /// Returns a local file URL when the track is downloaded, else nil.
    /// Set by the app (backed by DownloadManager) to avoid a dependency cycle.
    var localFileProvider: ((String) -> URL?)?

    // MARK: - Player internals

    private let player = AVQueuePlayer()
    private var queue: [PlayableTrack] = []
    private var playOrder: [Int] = []
    private var position: Int = 0
    private var enqueuedItems: [AVPlayerItem] = []
    private var cancellables = Set<AnyCancellable>()
    private var artworkCache: [String: UIImage] = [:]
    private var wasPlayingBeforeInterruption = false

    init(api: APIClient, config: AppConfig) {
        self.api = api
        self.config = config
        super.init()
        configureAudioSession()
        observePlayer()
        observeNotifications()
        configureRemoteCommands()
    }

    // MARK: - Queue control

    /// Replace the queue and start playing at `startIndex`.
    func play(_ tracks: [PlayableTrack], startIndex: Int = 0) {
        guard !tracks.isEmpty else { return }
        queue = tracks
        playOrder = Array(tracks.indices)
        if shuffle { shuffleUpcoming(keepCurrent: nil) }
        position = max(0, min(startIndex, playOrder.count - 1))
        if shuffle, let idx = playOrder.firstIndex(of: startIndex) {
            // Move the chosen start track to the front of the shuffled order.
            playOrder.swapAt(0, idx)
            position = 0
        }
        rebuildPlayerItems()
        player.play()
    }

    func togglePlayPause() {
        isPlaying ? player.pause() : player.play()
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func next() {
        guard position + 1 < playOrder.count else {
            if repeatMode == .all { restartFromBeginning() }
            return
        }
        position += 1
        rebuildPlayerItems()
        player.play()
    }

    func previous() {
        // Standard behaviour: restart the track when >3s in, else go back.
        if elapsed > 3 || position == 0 {
            seek(to: 0)
            return
        }
        position -= 1
        rebuildPlayerItems()
        player.play()
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func toggleShuffle() { shuffle.toggle() }

    func cycleRepeatMode() {
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    // MARK: - Queue internals

    private var currentTrack: PlayableTrack? {
        guard playOrder.indices.contains(position) else { return nil }
        return queue[playOrder[position]]
    }

    private func reshufflePreservingCurrent() {
        guard !queue.isEmpty, playOrder.indices.contains(position) else { return }
        let currentIdx = playOrder[position]
        playOrder = Array(queue.indices)
        if shuffle { shuffleUpcoming(keepCurrent: currentIdx) }
        position = playOrder.firstIndex(of: currentIdx) ?? 0
        rebuildPlayerItems()
    }

    /// Fisher–Yates over the upcoming portion, keeping the current item first.
    private func shuffleUpcoming(keepCurrent currentIdx: Int?) {
        var upcoming = playOrder
        let head: Int
        if let currentIdx, let i = upcoming.firstIndex(of: currentIdx) {
            head = upcoming.remove(at: i)
        } else {
            head = upcoming.removeFirst()
        }
        for i in stride(from: upcoming.count - 1, through: 1, by: -1) {
            upcoming.swapAt(i, Int.random(in: 0...i))
        }
        playOrder = [head] + upcoming
        position = 0
    }

    private func rebuildPlayerItems() {
        player.removeAllItems()
        enqueuedItems = []
        for orderIndex in playOrder[position...] {
            let playable = queue[orderIndex]
            guard let item = makePlayerItem(for: playable) else { continue }
            enqueuedItems.append(item)
            player.insert(item, after: nil)
        }
        updateActionAtItemEnd()
        // currentItem KVO fires asynchronously; update UI state eagerly.
        current = currentTrack
        hasQueue = !queue.isEmpty
        updateNowPlayingInfo()
    }

    private func restartFromBeginning() {
        position = 0
        if shuffle { shuffleUpcoming(keepCurrent: nil) }
        rebuildPlayerItems()
        player.play()
    }

    private func updateActionAtItemEnd() {
        // Repeat-one: hold at the end so we can seek back instead of advancing.
        player.actionAtItemEnd = (repeatMode == .one) ? .none : .advance
    }

    private func makePlayerItem(for playable: PlayableTrack) -> AVPlayerItem? {
        if let local = localFileProvider?(playable.track.id),
           FileManager.default.fileExists(atPath: local.path) {
            return AVPlayerItem(url: local)
        }
        guard let remote = try? api.streamURL(for: playable.track.id) else { return nil }
        let headers = config.authorizationHeaders
        if headers.isEmpty {
            return AVPlayerItem(url: remote)
        }
        // AVPlayer cannot set per-request headers on a bare URL; the asset
        // options dictionary is the supported injection point.
        let asset = AVURLAsset(url: remote, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        return AVPlayerItem(asset: asset)
    }

    // MARK: - Observers (all hop back to the main actor)

    private func observePlayer() {
        player.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    self.isPlaying = (status == .playing)
                    self.updateNowPlayingPlaybackState()
                }
            }
            .store(in: &cancellables)

        // Keep `position` in sync when AVQueuePlayer auto-advances.
        player.publisher(for: \.currentItem)
            .sink { [weak self] item in
                Task { @MainActor in
                    guard let self else { return }
                    if let item, let idx = self.enqueuedItems.firstIndex(of: item) {
                        self.position += idx
                        self.enqueuedItems.removeFirst(idx)
                    }
                    self.current = self.currentTrack
                    self.updateNowPlayingInfo()
                }
            }
            .store(in: &cancellables)

        // Progress + duration for the seek UI.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let elapsed = time.seconds
                guard elapsed.isFinite else { return }
                self.elapsed = elapsed
                if let dur = self.player.currentItem?.duration.seconds,
                   dur.isFinite, dur > 0 {
                    self.duration = dur
                    self.progress = min(max(elapsed / dur, 0), 1)
                }
                self.updateNowPlayingElapsed()
            }
        }
    }

    private func observeNotifications() {
        let center = NotificationCenter.default

        center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let item = note.object as? AVPlayerItem,
                      item == self.player.currentItem else { return }
                switch self.repeatMode {
                case .one:
                    self.player.seek(to: .zero)
                    self.player.play()
                case .all:
                    // If this was the final item, wrap to the start.
                    if self.enqueuedItems.last == item {
                        self.restartFromBeginning()
                    }
                case .off:
                    break
                }
            }
        }

        center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    self.wasPlayingBeforeInterruption = self.isPlaying
                    self.player.pause()
                case .ended:
                    let opts = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    if AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume),
                       self.wasPlayingBeforeInterruption {
                        self.player.play()
                    }
                @unknown default:
                    break
                }
            }
        }

        center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
                else { return }
                // Headphones unplugged: stop rather than blasting from the speaker.
                self.player.pause()
            }
        }
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            // Playback usually still works; never crash over session setup.
            print("[PlaybackEngine] audio session error: \(error)")
        }
    }

    // MARK: - Now Playing + remote commands

    /// Remote-command handlers are nonisolated; hop to the engine's methods.
    private func hop(_ work: @escaping @MainActor (PlaybackEngine) -> Void) -> MPRemoteCommandHandlerStatus {
        let captured = work
        Task { @MainActor [weak self] in
            guard let self else { return }
            captured(self)
        }
        return .success
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.hop { $0.play() }
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.hop { $0.pause() }
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.hop { $0.togglePlayPause() }
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.hop { $0.next() }
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.hop { $0.previous() }
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = e.positionTime
            return self.hop { $0.seek(to: position) }
        }
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        if let track = current {
            info[MPMediaItemPropertyTitle] = track.track.title
            info[MPMediaItemPropertyArtist] = track.artist
            info[MPMediaItemPropertyAlbumTitle] = track.album
            info[MPMediaItemPropertyPlaybackDuration] = track.track.duration_s
            loadArtwork(for: track) { [weak self] image in
                Task { @MainActor in
                    guard let self, let image, self.current?.id == track.id else { return }
                    var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    updated[MPMediaItemPropertyArtwork] =
                        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
                }
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        updateNowPlayingPlaybackState()
    }

    private func updateNowPlayingPlaybackState() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingElapsed() {
        guard MPNowPlayingInfoCenter.default().nowPlayingInfo != nil else { return }
        updateNowPlayingPlaybackState()
    }

    /// Best-effort artwork: the video's YouTube thumbnail, cached in memory.
    private func loadArtwork(for playable: PlayableTrack, completion: @escaping (UIImage?) -> Void) {
        if let cached = artworkCache[playable.id] {
            completion(cached)
            return
        }
        guard let url = URL(string: "https://i.ytimg.com/vi/\(playable.youtubeID)/hqdefault.jpg") else {
            completion(nil)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image: UIImage? = data.flatMap(UIImage.init)
            Task { @MainActor in
                if let image { self?.artworkCache[playable.id] = image }
                completion(image)
            }
        }.resume()
    }
}
