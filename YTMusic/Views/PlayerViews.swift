import SwiftUI

// MARK: - Mini player (pinned above the tab bar)

struct MiniPlayerView: View {
    let playable: PlayableTrack
    var onTap: () -> Void

    @Environment(PlaybackEngine.self) private var player

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ArtworkView(youtubeID: playable.youtubeID, size: 40, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playable.track.title)
                        .lineLimit(1)
                        .font(.subheadline)
                    Text(playable.artist)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 4)
        }
        .buttonStyle(.plain)
        // Thin progress bar along the bottom edge.
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * player.progress, height: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 2)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Full-screen now playing

struct NowPlayingView: View {
    @Environment(PlaybackEngine.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var sliderValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let current = player.current {
                    ArtworkView(youtubeID: current.youtubeID, size: 280, cornerRadius: 16)
                        .shadow(radius: 8)

                    VStack(spacing: 4) {
                        Text(current.track.title)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        Text(current.artist)
                            .foregroundStyle(.secondary)
                        Text(current.album)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal)

                    // Seek bar
                    VStack(spacing: 4) {
                        Slider(
                            value: $sliderValue,
                            in: 0...max(player.duration, 1),
                            onEditingChanged: { editing in
                                isScrubbing = editing
                                if !editing {
                                    player.seek(to: sliderValue)
                                }
                            }
                        )
                        HStack {
                            Text(formatTime(isScrubbing ? sliderValue : player.elapsed))
                            Spacer()
                            Text(formatTime(player.duration))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 24)
                    .onChange(of: player.elapsed) { _, newValue in
                        if !isScrubbing { sliderValue = newValue }
                    }
                    .onAppear { sliderValue = player.elapsed }

                    // Transport controls
                    HStack(spacing: 36) {
                        Button { player.toggleShuffle() } label: {
                            Image(systemName: "shuffle")
                                .font(.title2)
                                .foregroundStyle(player.shuffle ? Color.accentColor : .secondary)
                        }
                        Button { player.previous() } label: {
                            Image(systemName: "backward.fill").font(.largeTitle)
                        }
                        Button { player.togglePlayPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 64))
                        }
                        Button { player.next() } label: {
                            Image(systemName: "forward.fill").font(.largeTitle)
                        }
                        Button { player.cycleRepeatMode() } label: {
                            repeatIcon
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)

                    // Track meta
                    Text("\(current.track.codec.uppercased()) · \(current.track.sample_rate / 1000)kHz")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    ContentUnavailableView("Nothing Playing", systemImage: "music.note")
                }
                Spacer()
            }
            .padding(.top, 24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var repeatIcon: some View {
        let name: String = switch player.repeatMode {
        case .off: "repeat"
        case .all: "repeat"
        case .one: "repeat.1"
        }
        Image(systemName: name)
            .font(.title2)
            .foregroundStyle(player.repeatMode == .off ? .secondary : Color.accentColor)
            .overlay(alignment: .bottomTrailing) {
                if player.repeatMode == .one {
                    // repeat.1 already shows the badge; nothing extra needed.
                    EmptyView()
                }
            }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
