import SwiftUI

struct BackupRunStatus: Codable, Sendable {
    let date: Date
    let summary: String
    let failed: Bool
}

extension Settings {
    static var backupDestination: BackupDestination? {
        guard let data = UserDefaults.standard.data(forKey: "backupDestination") else { return nil }
        return try? JSONDecoder().decode(BackupDestination.self, from: data)
    }

    static func saveBackup(_ draft: BackupDestination, secret: String) throws -> BackupDestination {
        let destination = try draft.validated()
        if secret.isEmpty {
            _ = try BackupKeychain.read(for: destination, interactive: true)
        } else {
            try BackupKeychain.save(secret, for: destination)
        }
        UserDefaults.standard.set(try JSONEncoder().encode(destination), forKey: "backupDestination")
        return destination
    }

    static var lastBackup: BackupRunStatus? {
        guard let data = UserDefaults.standard.data(forKey: "lastBackup") else { return nil }
        return try? JSONDecoder().decode(BackupRunStatus.self, from: data)
    }

    static func runBackup(interactive: Bool) async -> BackupRunStatus {
        let result: BackupRunStatus
        do {
            guard let destination = backupDestination else { throw BackupError("Save a backup destination first.") }
            let secret = try BackupKeychain.read(for: destination, interactive: interactive)
            let uploader = S3Upload(destination: destination, secret: secret)
            let activePrefix = screenshotPrefix
            let prefixes = activePrefix == ArchiveService.defaultPrefix ? [activePrefix] : [activePrefix, ArchiveService.defaultPrefix]
            let summary = try await ObjectBackup(folder: folder, screenshotPrefixes: prefixes).run(upload: uploader.upload)
            result = BackupRunStatus(date: Date(), summary: summary, failed: false)
        } catch {
            result = BackupRunStatus(date: Date(), summary: error.localizedDescription, failed: true)
        }
        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: "lastBackup")
        }
        log("Object storage backup: \(result.summary)")
        return result
    }
}

struct BackupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var saved = Settings.backupDestination
    @State private var draft = Settings.backupDestination ?? BackupDestination()
    @State private var secret = ""
    @State private var status: LaunchAgentStatus?
    @State private var lastRun = Settings.lastBackup
    @State private var busy = false
    @State private var error: String?

    private var hasEdits: Bool { draft != saved || !secret.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Object storage backups").font(.title2.bold())
            Text("Save a dated ZIP of current and archived screenshots to an S3-compatible bucket.")
                .font(.callout).foregroundStyle(.secondary)

            Form {
                TextField("Endpoint", text: $draft.endpoint, prompt: Text("Leave blank for Amazon S3"))
                TextField("Region", text: $draft.region)
                TextField("Bucket", text: $draft.bucket)
                TextField("Prefix", text: $draft.prefix)
                TextField("Access key ID", text: $draft.accessKeyID)
                SecureField("Secret access key", text: $secret, prompt: Text(saved == nil ? "Stored in Keychain" : "Leave blank to keep saved key"))
            }
            Button("Save Destination", action: save)
                .disabled(!hasEdits)
            Divider()

            if let enabled = status?.isEnabled {
                Toggle("Back up daily at 8 PM", isOn: Binding(get: { enabled }, set: setSchedule))
                    .disabled(!enabled && (saved == nil || hasEdits))
                if let reason = status?.repairMessage {
                    HStack {
                        Text(reason).font(.caption)
                        Button("Update Schedule") { setSchedule(true) }
                            .disabled(saved == nil || hasEdits)
                    }
                }
            } else if case .unavailable(let reason) = status {
                Text(reason).font(.caption).foregroundStyle(.red)
                Button("Retry Schedule Check") { Task { await refreshStatus() } }
            } else {
                Text("Checking daily schedule…").font(.caption)
            }

            if let lastRun {
                Text("\(lastRun.date.formatted(date: .abbreviated, time: .shortened)) · \(lastRun.summary)")
                    .font(.caption).foregroundStyle(lastRun.failed ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }

            HStack {
                Button("Back Up Now", action: backUpNow).disabled(saved == nil || hasEdits)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .task { await refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            lastRun = Settings.lastBackup
        }
    }

    private func refreshStatus() async {
        status = await Task.detached { LaunchAgent.scheduled(.backup).status() }.value
    }

    private func save() {
        busy = true
        error = nil
        let destination = draft
        let newSecret = secret
        Task {
            defer { busy = false }
            do {
                let result = try await Task.detached { try Settings.saveBackup(destination, secret: newSecret) }.value
                draft = result
                saved = result
                secret = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func setSchedule(_ enabled: Bool) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await Task.detached { try LaunchAgent.scheduled(.backup).setAutomatic(enabled) }.value
            } catch {
                self.error = error.localizedDescription
            }
            await refreshStatus()
        }
    }

    private func backUpNow() {
        busy = true
        error = nil
        Task {
            lastRun = await Settings.runBackup(interactive: true)
            busy = false
        }
    }
}
