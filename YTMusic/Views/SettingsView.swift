import SwiftUI

/// Settings tab: server connection, API token, offline storage.
struct SettingsView: View {
    @Environment(AppConfig.self) private var config
    @Environment(APIClient.self) private var api
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryStore.self) private var library

    @State private var serverField: String = ""
    @State private var tokenField: String = ""
    @State private var health: Health?
    @State private var testMessage: String?
    @State private var isTesting = false
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("http://192.168.1.10:8000", text: $serverField)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API token (optional)", text: $tokenField)
                    Button("Save & Test Connection") {
                        saveAndTest()
                    }
                    .disabled(serverField.trimmingCharacters(in: .whitespaces).isEmpty)
                    if isTesting {
                        ProgressView()
                    }
                    if let testMessage {
                        Text(testMessage)
                            .font(.caption)
                            .foregroundStyle(health != nil ? .green : .red)
                    }
                    if let health {
                        LabeledContent("Server version", value: health.version)
                        LabeledContent("Database", value: health.database)
                        LabeledContent("Worker", value: health.worker_alive ? "alive" : "not seen")
                    }
                }

                Section("Offline Storage") {
                    let mb = Double(downloads.totalDownloadedBytes) / 1_000_000
                    LabeledContent("Downloaded audio", value: String(format: "%.1f MB", mb))
                    Button("Remove All Downloads", role: .destructive) {
                        showClearConfirm = true
                    }
                    .confirmationDialog(
                        "Remove all downloaded tracks?",
                        isPresented: $showClearConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Remove All", role: .destructive) {
                            downloads.deleteAllDownloads()
                        }
                    }
                }

                Section("About") {
                    LabeledContent("App version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    Text("Personal music player. Streams ALAC audio from your private server; downloads are for your offline use.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                serverField = config.serverBaseURLString
                tokenField = config.apiToken
            }
        }
    }

    private func saveAndTest() {
        config.serverBaseURLString = serverField.trimmingCharacters(in: .whitespacesAndNewlines)
        config.apiToken = tokenField.trimmingCharacters(in: .whitespacesAndNewlines)
        health = nil
        testMessage = nil
        isTesting = true
        Task {
            defer { isTesting = false }
            do {
                // /healthz needs no auth on the backend, so this validates
                // reachability even before the token is right.
                let h = try await api.health()
                health = h
                testMessage = "Connected."
                await library.refresh()
            } catch {
                testMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
