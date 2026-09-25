import SwiftUI

/// Add tab: paste a YouTube URL, optionally pick a target playlist, submit,
/// and watch the ingest job's live progress until the tracks land.
struct AddVideoView: View {
    @Environment(AppConfig.self) private var config
    @Environment(APIClient.self) private var api
    @Environment(LibraryStore.self) private var library

    @State private var urlString = ""
    @State private var selectedPlaylistID: String?
    @State private var job: Job?
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                if config.baseURL == nil {
                    Section {
                        Text("Set your server URL in Settings before adding videos.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("YouTube URL") {
                        TextField("https://www.youtube.com/watch?v=…", text: $urlString)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }

                    Section("Playlist") {
                        Picker("Add to playlist", selection: $selectedPlaylistID) {
                            Text("None").tag(nil as String?)
                            ForEach(library.playlists) { playlist in
                                Text(playlist.name).tag(playlist.id as String?)
                            }
                        }
                        Text("Tracks are split from the video's chapters and added when the job finishes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        Button {
                            submit()
                        } label: {
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text("Add Video")
                            }
                        }
                        .disabled(!canSubmit || isSubmitting)
                    }

                    if let errorMessage {
                        Section {
                            Text(errorMessage).foregroundStyle(.red).font(.caption)
                        }
                    }

                    if let job {
                        Section("Ingest Job") {
                            JobStatusView(job: job)
                        }
                    }
                }
            }
            .navigationTitle("Add")
            .onDisappear { pollTask?.cancel() }
        }
    }

    private var canSubmit: Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 8 && (trimmed.contains("youtube.com") || trimmed.contains("youtu.be"))
    }

    private func submit() {
        errorMessage = nil
        pollTask?.cancel()
        let url = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                let newJob = try await api.ingest(url: url, playlistID: selectedPlaylistID)
                job = newJob
                urlString = ""
                if newJob.isTerminal {
                    await library.refresh()
                } else {
                    startPolling(id: newJob.job_id)
                }
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func startPolling(id: String) {
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                do {
                    let updated = try await api.job(id: id)
                    job = updated
                    if updated.isTerminal {
                        await library.refresh()
                        return
                    }
                } catch {
                    // A transient poll failure shouldn't kill the loop; surface
                    // it only if polling keeps failing. Keep it simple: stop.
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    return
                }
            }
        }
    }
}

/// Live job progress card.
struct JobStatusView: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statusIcon
                VStack(alignment: .leading) {
                    Text(statusText).font(.headline)
                    Text("Stage: \(job.stage) · attempt \(job.attempt)/\(job.max_attempts)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if job.existing {
                    Text("Already in library")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            if !job.isTerminal {
                ProgressView(value: job.progress)
            }
            if job.isFailed {
                if let code = job.error_code {
                    Text("Error: \(code)").font(.caption).foregroundStyle(.red)
                }
                if let message = job.error_message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if job.error_code == "AUTH_REQUIRED" {
                    Text("YouTube is bot-checking the server's network. Try again from a home network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if job.status == "done" {
                Label("Tracks are in your library.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch job.status {
        case "queued": return "Queued"
        case "running": return "Processing"
        case "done": return "Done"
        case "failed": return "Failed"
        default: return job.status.capitalized
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case "done":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "failed":
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        default:
            ProgressView()
        }
    }
}
