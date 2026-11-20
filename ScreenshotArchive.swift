import AppKit
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UserNotifications

struct AutoRunStatus: Equatable, Sendable {
    let date: Date
    let moved: Int
    let error: String?
}

enum ProblemKind: Equatable, Sendable {
    case permission(String)
    case missingFolder(String)
    case general(String)

    var message: String {
        switch self {
        case .permission(let text), .missingFolder(let text), .general(let text):
            return text
        }
    }
}

enum Settings {
    static let daysKey = "archiveDays"
    static let organizeByMonthKey = "organizeByMonth"
    static let customFolderKey = "customFolderPath"
    static let lastAutoRunDateKey = "lastAutoRunDate"
    static let lastAutoRunMovedKey = "lastAutoRunMoved"
    static let lastAutoRunErrorKey = "lastAutoRunError"
    static let notifyOnAutoFailureKey = "notifyOnAutoFailure"
    static let lastFailureNotifCategoryKey = "lastFailureNotifCategory"
    static let lastFailureNotifDateKey = "lastFailureNotifDate"

    private static let maxLogBytes = 256 * 1024
    private static let trimmedLogLines = 250

    static var defaultFolder: URL {
        if let configured = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (configured as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Screenshots", isDirectory: true)
    }

    static var customFolder: URL? {
        get {
            guard let custom = UserDefaults.standard.string(forKey: customFolderKey), !custom.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        set {
            if let newValue, newValue.standardizedFileURL != defaultFolder.standardizedFileURL {
                UserDefaults.standard.set(newValue.path, forKey: customFolderKey)
            } else {
                UserDefaults.standard.removeObject(forKey: customFolderKey)
            }
        }
    }

    static var folder: URL {
        get { customFolder ?? defaultFolder }
        set { customFolder = newValue }
    }

    static var screenshotPrefix: String {
        ArchiveService.detectedPrefix()
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ScreenshotArchive.log")
    }

    static var days: Int {
        get { max(1, UserDefaults.standard.object(forKey: daysKey) as? Int ?? 3) }
        set { UserDefaults.standard.set(max(1, newValue), forKey: daysKey) }
    }

    static var organizeByMonth: Bool {
        get { UserDefaults.standard.bool(forKey: organizeByMonthKey) }
        set { UserDefaults.standard.set(newValue, forKey: organizeByMonthKey) }
    }

    static var notifyOnAutoFailure: Bool {
        get { UserDefaults.standard.bool(forKey: notifyOnAutoFailureKey) }
        set { UserDefaults.standard.set(newValue, forKey: notifyOnAutoFailureKey) }
    }

    static var failureNotificationState: FailureNotificationState {
        get {
            let category = UserDefaults.standard.string(forKey: lastFailureNotifCategoryKey)
            let timestamp = UserDefaults.standard.object(forKey: lastFailureNotifDateKey) as? Double
            return FailureNotificationState(
                lastCategory: category,
                lastSentAt: timestamp.map { Date(timeIntervalSince1970: $0) }
            )
        }
        set {
            if let category = newValue.lastCategory {
                UserDefaults.standard.set(category, forKey: lastFailureNotifCategoryKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastFailureNotifCategoryKey)
            }
            if let date = newValue.lastSentAt {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastFailureNotifDateKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastFailureNotifDateKey)
            }
        }
    }

    static var lastAutoRun: AutoRunStatus? {
        guard let timestamp = UserDefaults.standard.object(forKey: lastAutoRunDateKey) as? Double else {
            return nil
        }
        let moved = UserDefaults.standard.integer(forKey: lastAutoRunMovedKey)
        let error = UserDefaults.standard.string(forKey: lastAutoRunErrorKey)
        return AutoRunStatus(date: Date(timeIntervalSince1970: timestamp), moved: moved, error: error)
    }

    static func recordAutoRun(moved: Int, error: String?) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastAutoRunDateKey)
        UserDefaults.standard.set(moved, forKey: lastAutoRunMovedKey)
        if let error, !error.isEmpty {
            UserDefaults.standard.set(error, forKey: lastAutoRunErrorKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastAutoRunErrorKey)
        }
    }

    static func notifyBackgroundFailureIfNeeded(category: FailureCategory, failedCount: Int = 0) async {
        guard notifyOnAutoFailure, Bundle.main.bundleIdentifier != nil else { return }
        let now = Date()
        guard FailureNotificationPolicy.shouldNotify(category: category, state: failureNotificationState, now: now) else {
            return
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Screenshot Archive"
        content.body = FailureNotificationPolicy.notificationBody(for: category, failedCount: failedCount)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.jmitch.screenshot-archive.auto-failure.\(category.rawValue)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            failureNotificationState = FailureNotificationState(lastCategory: category.rawValue, lastSentAt: now)
        } catch {
            log("Could not post failure notification: \(error.localizedDescription)")
        }
    }

    static func displayPath(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path == home { return "~" }
        if url.path.hasPrefix(home + "/") {
            return "~" + url.path.dropFirst(home.count)
        }
        return url.path
    }

    static func log(_ message: String) {
        let fm = FileManager.default
        let url = logURL
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int,
           size > maxLogBytes,
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            let kept = lines.suffix(trimmedLogLines).joined(separator: "\n") + "\n"
            try? kept.write(to: url, atomically: true, encoding: .utf8)
        }

        let timestamp = Date().formatted(.iso8601)
        let data = Data("\(timestamp): \(message)\n".utf8)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}

@MainActor
final class ArchiveModel: ObservableObject {
    @Published var scan = ArchiveScan()
    @Published var archiveStats = ArchiveStats()
    @Published var agentStatus: LaunchAgentStatus?
    @Published var scheduleError: String?
    @Published var lastAutoRun: AutoRunStatus? = Settings.lastAutoRun
    @Published var days: Int = Settings.days
    @Published var organizeByMonth: Bool = Settings.organizeByMonth
    @Published var notifyOnAutoFailure: Bool = Settings.notifyOnAutoFailure
    @Published var customFolder: URL? = Settings.customFolder
    @Published var screenshotPrefix: String = Settings.screenshotPrefix
    @Published var message = ""
    @Published var problem: ProblemKind?
    @Published var lastMoves: [ArchiveMove] = []
    @Published var quickLookURL: URL?
    @Published var isRefreshing = false
    @Published var isMutating = false
    @Published var isUpdatingSchedule = false

    private var refreshTask: Task<Void, Never>?
    private var refreshRevision = 0
    private var scheduleRevision = 0

    var isBusy: Bool { isRefreshing || isMutating }
    var hasCustomFolder: Bool { customFolder != nil }
    var folder: URL { customFolder ?? Settings.defaultFolder }

    func makeService(prefix: String? = nil) -> ArchiveService {
        ArchiveService(
            folder: folder,
            organizeByMonth: organizeByMonth,
            screenshotPrefix: prefix ?? screenshotPrefix
        )
    }

    func updateDays(_ newValue: Int) {
        let clamped = max(1, newValue)
        guard days != clamped else { return }
        days = clamped
        Settings.days = clamped
        message = ""
        refresh()
    }

    func updateOrganizeByMonth(_ enabled: Bool) {
        guard organizeByMonth != enabled else { return }
        organizeByMonth = enabled
        Settings.organizeByMonth = enabled
        message = ""
        refresh()
    }

    func updateNotifyOnAutoFailure(_ enabled: Bool) {
        guard !enabled else {
            guard Bundle.main.bundleIdentifier != nil else { return }
            Task {
                do {
                    let granted = try await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound])
                    notifyOnAutoFailure = granted
                    Settings.notifyOnAutoFailure = granted
                    if !granted {
                        scheduleError = "Allow notifications for Screenshot Archive in System Settings → Notifications."
                    } else {
                        scheduleError = nil
                    }
                } catch {
                    notifyOnAutoFailure = false
                    Settings.notifyOnAutoFailure = false
                    scheduleError = error.localizedDescription
                }
            }
            return
        }
        notifyOnAutoFailure = false
        Settings.notifyOnAutoFailure = false
        scheduleError = nil
    }

    func chooseFolder() {
        guard !isMutating else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Select"
        panel.message = "Choose the folder where macOS saves your screenshots."
        if panel.runModal() == .OK, let selected = panel.url {
            Settings.customFolder = selected
            customFolder = Settings.customFolder
            lastMoves = []
            message = ""
            refresh()
        }
    }

    func resetDefaultFolder() {
        guard !isMutating else { return }
        Settings.customFolder = nil
        customFolder = nil
        lastMoves = []
        message = ""
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshRevision += 1
        let activeRefresh = refreshRevision
        let activeSchedule = scheduleRevision
        let detectedPrefix = Settings.screenshotPrefix
        screenshotPrefix = detectedPrefix
        let currentService = makeService(prefix: detectedPrefix)
        let currentDays = days

        isRefreshing = true
        refreshTask = Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                () -> (Result<ArchiveScan, Error>, ArchiveStats, LaunchAgentStatus) in
                let scanResult = Result { try currentService.scan(days: currentDays) }
                let stats = currentService.archiveStats()
                let status = LaunchAgent.current.status()
                return (scanResult, stats, status)
            }.value

            guard activeRefresh == refreshRevision else { return }
            isRefreshing = false

            switch outcome.0 {
            case .success(let newScan):
                scan = newScan
                problem = nil
                reconcileQuickLookSelection()
            case .failure(let error):
                scan = ArchiveScan()
                quickLookURL = nil
                problem = classifyError(error, folder: currentService.folder)
            }
            archiveStats = outcome.1
            if activeSchedule == scheduleRevision && !isUpdatingSchedule {
                agentStatus = outcome.2
            }
            lastAutoRun = Settings.lastAutoRun
        }
    }

    func clean() {
        guard !isMutating else { return }
        refreshTask?.cancel()
        refreshRevision += 1
        isRefreshing = false
        isMutating = true

        let detectedPrefix = Settings.screenshotPrefix
        screenshotPrefix = detectedPrefix
        let currentService = makeService(prefix: detectedPrefix)
        let currentDays = days

        Task {
            let cleanResult = await Task.detached(priority: .userInitiated) {
                Result { try currentService.clean(days: currentDays) }
            }.value

            isMutating = false
            switch cleanResult {
            case .success(let result):
                lastMoves = result.moves
                message = "Moved \(result.moved) screenshot\(result.moved == 1 ? "" : "s") into Archive."
                if result.moved > 0 || !result.errors.isEmpty {
                    let suffix = result.errors.isEmpty ? "" : " Errors: \(result.errors.joined(separator: "; "))"
                    Settings.log(message + suffix)
                }
                if !result.errors.isEmpty {
                    problem = .general(result.errors.joined(separator: "\n"))
                } else {
                    problem = nil
                }
                await refreshKeepingProblemIfNeeded(preserveError: !result.errors.isEmpty)
            case .failure(let error):
                problem = classifyError(error, folder: currentService.folder)
            }
        }
    }

    func organizeExistingArchive() {
        guard !isMutating else { return }
        refreshTask?.cancel()
        refreshRevision += 1
        isRefreshing = false
        isMutating = true

        let detectedPrefix = Settings.screenshotPrefix
        screenshotPrefix = detectedPrefix
        let currentService = makeService(prefix: detectedPrefix)

        Task {
            let organizeResult = await Task.detached(priority: .userInitiated) {
                Result { try currentService.organizeArchive() }
            }.value

            isMutating = false
            switch organizeResult {
            case .success(let result):
                lastMoves = result.moves
                var parts = ["Organized \(result.moved) archived screenshot\(result.moved == 1 ? "" : "s") into YYYY-MM folders"]
                if result.skippedCollisions > 0 {
                    parts.append("skipped \(result.skippedCollisions) collision\(result.skippedCollisions == 1 ? "" : "s")")
                }
                message = parts.joined(separator: ", ") + "."
                if result.moved > 0 || !result.errors.isEmpty {
                    let suffix = result.errors.isEmpty ? "" : " Errors: \(result.errors.joined(separator: "; "))"
                    Settings.log(message + suffix)
                }
                if !result.errors.isEmpty {
                    problem = .general(result.errors.joined(separator: "\n"))
                } else {
                    problem = nil
                }
                await refreshKeepingProblemIfNeeded(preserveError: !result.errors.isEmpty)
            case .failure(let error):
                problem = classifyError(error, folder: currentService.archive)
            }
        }
    }

    func renameCandidateToKeep(_ candidate: ArchiveCandidate, newStem: String) async throws {
        guard !isMutating else { return }
        refreshTask?.cancel()
        refreshRevision += 1
        isRefreshing = false
        isMutating = true
        defer { isMutating = false }

        let detectedPrefix = Settings.screenshotPrefix
        screenshotPrefix = detectedPrefix
        let currentService = makeService(prefix: detectedPrefix)

        let renamed = try await Task.detached(priority: .userInitiated) {
            try currentService.renameToKeep(candidate.url, newStem: newStem)
        }.value

        message = "Kept \"\(renamed.lastPathComponent)\" out of Archive."
        Settings.log("Renamed \(candidate.name) -> \(renamed.lastPathComponent)")
        await refreshKeepingProblemIfNeeded(preserveError: false)
    }

    func undoLastClean() {
        guard !isMutating, !lastMoves.isEmpty else { return }
        refreshTask?.cancel()
        refreshRevision += 1
        isRefreshing = false
        isMutating = true

        let movesToRestore = lastMoves
        let currentService = makeService()

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                currentService.restore(movesToRestore)
            }.value

            isMutating = false
            lastMoves = []
            var parts = ["Restored \(result.restored) screenshot\(result.restored == 1 ? "" : "s")"]
            if result.skipped > 0 {
                parts.append("skipped \(result.skipped)")
            }
            message = parts.joined(separator: ", ") + "."
            Settings.log("Undo: \(message)")

            if !result.errors.isEmpty {
                problem = .general(result.errors.joined(separator: "\n"))
            }
            await refreshKeepingProblemIfNeeded(preserveError: !result.errors.isEmpty)
        }
    }

    func setAutomatic(_ enabled: Bool) {
        guard !isUpdatingSchedule else { return }
        isUpdatingSchedule = true
        scheduleError = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (Error?, LaunchAgentStatus) in
                do {
                    try LaunchAgent.current.setAutomatic(enabled)
                    return (nil, LaunchAgent.current.status())
                } catch {
                    return (error, LaunchAgent.current.status())
                }
            }.value

            scheduleRevision += 1
            isUpdatingSchedule = false
            agentStatus = outcome.1
            lastAutoRun = Settings.lastAutoRun
            if let error = outcome.0 {
                scheduleError = error.localizedDescription
            } else if enabled {
                // Refresh shortly after launchctl RunAtLoad triggers a background run.
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                refresh()
            }
        }
    }

    func openArchive() {
        do {
            try FileManager.default.createDirectory(at: makeService().archive, withIntermediateDirectories: true)
            NSWorkspace.shared.open(makeService().archive)
        } catch {
            problem = classifyError(error, folder: makeService().archive)
        }
    }

    func openSourceFolder() {
        NSWorkspace.shared.open(folder)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLogFile() {
        let url = Settings.logURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func refreshKeepingProblemIfNeeded(preserveError: Bool) async {
        refreshRevision += 1
        let activeRefresh = refreshRevision
        let activeSchedule = scheduleRevision
        let currentService = makeService()
        let currentDays = days

        isRefreshing = true
        let outcome = await Task.detached(priority: .userInitiated) {
            () -> (Result<ArchiveScan, Error>, ArchiveStats, LaunchAgentStatus) in
            let scanResult = Result { try currentService.scan(days: currentDays) }
            let stats = currentService.archiveStats()
            let status = LaunchAgent.current.status()
            return (scanResult, stats, status)
        }.value

        guard activeRefresh == refreshRevision else { return }
        isRefreshing = false

        switch outcome.0 {
        case .success(let newScan):
            scan = newScan
            reconcileQuickLookSelection()
            if !preserveError { problem = nil }
        case .failure(let error):
            scan = ArchiveScan()
            quickLookURL = nil
            problem = classifyError(error, folder: currentService.folder)
        }
        archiveStats = outcome.1
        if activeSchedule == scheduleRevision && !isUpdatingSchedule {
            agentStatus = outcome.2
        }
        lastAutoRun = Settings.lastAutoRun
    }

    private func reconcileQuickLookSelection() {
        if let current = quickLookURL, !scan.candidates.contains(where: { $0.url == current }) {
            quickLookURL = nil
        }
    }

    private func classifyError(_ error: Error, folder: URL) -> ProblemKind {
        if ArchiveService.isPermissionError(error) {
            return .permission(
                "Allow Screenshot Archive to access \(Settings.displayPath(for: folder)) in System Settings → Privacy & Security → Files and Folders, then refresh."
            )
        }
        if ArchiveService.isMissingFolderError(error) {
            return .missingFolder(
                "Folder \(Settings.displayPath(for: folder)) doesn't exist yet. Choose a different folder or take a screenshot first."
            )
        }
        return .general(error.localizedDescription)
    }
}

private struct CandidateThumbnailView: View {
    let url: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            thumbnail = nil
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 48, height: 48),
                scale: 2.0,
                representationTypes: .thumbnail
            )
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
               !Task.isCancelled {
                thumbnail = rep.nsImage
            }
        }
    }
}

private struct KeepRenameSheet: View {
    let candidate: ArchiveCandidate
    let prefix: String
    let onRename: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newStem: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(candidate: ArchiveCandidate, prefix: String, onRename: @escaping (String) async throws -> Void) {
        self.candidate = candidate
        self.prefix = prefix
        self.onRename = onRename
        let stem = candidate.url.deletingPathExtension().lastPathComponent
        let stripped: String
        if stem.hasPrefix(prefix + " ") {
            stripped = String(stem.dropFirst(prefix.count + 1))
        } else {
            stripped = stem
        }
        _newStem = State(initialValue: stripped)
    }

    private var fileExtension: String {
        candidate.url.pathExtension
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keep Screenshot").font(.headline)
            Text("Rename this file without the \"\(prefix)\" prefix so it stays in the top-level folder. Kept files are also excluded from Screenshot Archive backups.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                TextField("New name", text: $newStem)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSaving)
                    .onSubmit(save)
                if !fileExtension.isEmpty {
                    Text(".\(fileExtension)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Keep & Rename", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || newStem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        let stem = newStem
        Task {
            defer { isSaving = false }
            do {
                try await onRename(stem)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct ArchiveView: View {
    @StateObject private var model = ArchiveModel()
    @State private var showingFiles = false
    @State private var showingBackups = false
    @State private var candidateToKeep: ArchiveCandidate?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerSection
            summaryCard
            settingsSection
            feedbackSection
            footerSection
        }
        .padding(24)
        .frame(width: 460)
        .quickLookPreview($model.quickLookURL)
        .sheet(isPresented: $showingBackups) { BackupView() }
        .sheet(item: $candidateToKeep) { candidate in
            KeepRenameSheet(candidate: candidate, prefix: model.screenshotPrefix) { newStem in
                try await model.renameCandidateToKeep(candidate, newStem: newStem)
            }
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    private var headerSection: some View {
        HStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 28))
                .foregroundStyle(.blue)
                .frame(width: 52, height: 52)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 4) {
                Text("Screenshot Archive")
                    .font(.title2.bold())
                HStack(spacing: 6) {
                    Button(action: model.openSourceFolder) {
                        Label(Settings.displayPath(for: model.folder), systemImage: "folder")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help("Open screenshots folder in Finder")

                    Text("·").font(.caption).foregroundStyle(.tertiary)

                    Button("Change…", action: model.chooseFolder)
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(model.isMutating)

                    if model.hasCustomFolder {
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                        Button("Reset", action: model.resetDefaultFolder)
                            .buttonStyle(.link)
                            .font(.caption)
                            .disabled(model.isMutating)
                    }
                }
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(model.scan.candidates.count)")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                Text("ready to archive")
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: { model.refresh() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh preview")
                }
            }

            Text("\(model.scan.recentCount) recent · \(ByteCountFormatter.string(fromByteCount: model.scan.bytes, countStyle: .file)) to move")
                .font(.callout)
                .foregroundStyle(.secondary)

            if model.archiveStats.fileCount > 0 || model.archiveStats.partial {
                let countText = "\(model.archiveStats.fileCount)\(model.archiveStats.partial ? "+" : "") file\(model.archiveStats.fileCount == 1 && !model.archiveStats.partial ? "" : "s")"
                let sizeText = ByteCountFormatter.string(fromByteCount: model.archiveStats.allocatedBytes, countStyle: .file)
                Text("Archive: \(countText) · \(sizeText) on disk\(model.archiveStats.partial ? " (partial)" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.scan.collisionCount > 0 {
                Text("\(model.scan.collisionCount) skipped because the name is already in Archive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.scan.candidates.isEmpty {
                DisclosureGroup("Preview files", isExpanded: $showingFiles) {
                    let rowHeight: CGFloat = 32
                    let listHeight = min(max(40, CGFloat(model.scan.candidates.count) * rowHeight + 8), 180)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(model.scan.candidates) { candidate in
                                    HStack(spacing: 8) {
                                        Button {
                                            model.quickLookURL = candidate.url
                                        } label: {
                                            HStack(spacing: 8) {
                                                CandidateThumbnailView(url: candidate.url)
                                                Text(candidate.name)
                                                    .font(.caption)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                    .foregroundStyle(.primary)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .help("Quick Look \(candidate.name)")

                                        Spacer(minLength: 6)

                                        Text("\(Self.relativeFormatter.localizedString(for: candidate.modifiedAt, relativeTo: context.date)) · \(ByteCountFormatter.string(fromByteCount: candidate.size, countStyle: .file))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()

                                        Button {
                                            candidateToKeep = candidate
                                        } label: {
                                            Image(systemName: "pin")
                                                .font(.caption2)
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(model.isMutating)
                                        .help("Rename to keep out of Archive")

                                        Button {
                                            model.revealInFinder(candidate.url)
                                        } label: {
                                            Image(systemName: "magnifyingglass")
                                                .font(.caption2)
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Reveal in Finder")
                                    }
                                    .frame(height: 28)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                        }
                        .frame(height: listHeight)
                    }
                }
                .font(.callout)
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Archive after")
                Spacer()
                Picker("Archive after", selection: Binding(
                    get: { model.days },
                    set: { model.updateDays($0) }
                )) {
                    ForEach([1, 3, 7, 14, 30], id: \.self) { day in
                        Text("\(day) day\(day == 1 ? "" : "s")").tag(day)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }

            HStack {
                Toggle("Organize Archive into YYYY-MM folders", isOn: Binding(
                    get: { model.organizeByMonth },
                    set: { model.updateOrganizeByMonth($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer()

                if model.organizeByMonth && model.archiveStats.flatMatchingCount > 0 {
                    Button("Organize \(model.archiveStats.flatMatchingCount) Existing") {
                        model.organizeExistingArchive()
                    }
                    .controlSize(.small)
                    .disabled(model.isMutating)
                }
            }

            if let enabled = model.agentStatus?.isEnabled {
                Toggle("Clean up automatically every hour", isOn: Binding(
                    get: { enabled },
                    set: { model.setAutomatic($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(model.isUpdatingSchedule)

                if enabled {
                    Toggle("Notify if automatic cleanup fails", isOn: Binding(
                        get: { model.notifyOnAutoFailure },
                        set: { model.updateNotifyOnAutoFailure($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            } else if case .unavailable(let reason) = model.agentStatus {
                HStack {
                    Text("Could not check hourly cleanup. \(reason)")
                        .font(.caption)
                    Button("Retry", action: model.refresh)
                        .controlSize(.small)
                }
            } else {
                Text("Checking hourly cleanup…").font(.caption)
            }

            if let error = model.scheduleError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let explanation = model.agentStatus?.repairMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Update Schedule") {
                        model.setAutomatic(true)
                    }
                    .controlSize(.small)
                    .disabled(model.isUpdatingSchedule)
                }
            }

            if let lastRun = model.lastAutoRun {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    HStack(spacing: 6) {
                        let age = Self.relativeFormatter.localizedString(for: lastRun.date, relativeTo: context.date)
                        if let error = lastRun.error {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text("Last auto run failed \(age): \(error)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                        } else {
                            let summary = lastRun.moved == 0 ? "all tidy" : "moved \(lastRun.moved)"
                            Text("Last auto check \(age) (\(summary))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Log", action: model.openLogFile)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }

            Text("Moves \"\(model.screenshotPrefix)\" images unchanged for \(model.days) day\(model.days == 1 ? "" : "s") into \(model.organizeByMonth ? "Archive/YYYY-MM" : "Archive"). Rename without the \"\(model.screenshotPrefix)\" prefix to keep a file here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = model.problem {
                Text(problem.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if case .permission = problem {
                    Button("Open Privacy Settings", action: model.openPrivacySettings)
                        .controlSize(.small)
                } else if case .missingFolder = problem {
                    Button("Choose Folder…", action: model.chooseFolder)
                        .controlSize(.small)
                        .disabled(model.isMutating)
                }
            }

            if !model.message.isEmpty || !model.lastMoves.isEmpty {
                HStack(spacing: 10) {
                    if !model.message.isEmpty {
                        Text(model.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !model.lastMoves.isEmpty {
                        Button("Undo", action: model.undoLastClean)
                            .controlSize(.small)
                            .disabled(model.isMutating)
                    }
                }
            }
        }
    }

    private var footerSection: some View {
        HStack {
            Button("Open Archive", action: model.openArchive)
            Button("Backups…") { showingBackups = true }
            Spacer()
            Button("Clean Up Now", action: model.clean)
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || model.scan.candidates.isEmpty || model.problem != nil)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct ScreenshotArchiveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--backup") {
            Task.detached {
                let result = await Settings.runBackup(interactive: false)
                exit(result.failed ? 1 : 0)
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--background") {
            Task.detached {
                let service = ArchiveService(
                    folder: Settings.folder,
                    organizeByMonth: Settings.organizeByMonth,
                    screenshotPrefix: Settings.screenshotPrefix
                )
                do {
                    let result = try service.clean(days: Settings.days)
                    let errorSummary = result.errors.isEmpty ? nil : result.errors.joined(separator: "; ")
                    Settings.recordAutoRun(moved: result.moved, error: errorSummary)
                    if result.moved > 0 || errorSummary != nil {
                        let suffix = errorSummary.map { " Errors: \($0)" } ?? ""
                        Settings.log("Automatic cleanup: moved \(result.moved) screenshot\(result.moved == 1 ? "" : "s").\(suffix)")
                    }
                    if result.errors.isEmpty {
                        Settings.failureNotificationState = FailureNotificationState()
                        exit(0)
                    } else {
                        await Settings.notifyBackgroundFailureIfNeeded(
                            category: .partialFailure,
                            failedCount: result.errors.count
                        )
                        exit(1)
                    }
                } catch {
                    Settings.recordAutoRun(moved: 0, error: error.localizedDescription)
                    Settings.log("Automatic cleanup failed: \(error.localizedDescription)")
                    await Settings.notifyBackgroundFailureIfNeeded(
                        category: FailureCategory.classify(error)
                    )
                    exit(1)
                }
            }
            dispatchMain()
        }
    }

    var body: some Scene {
        Window("Screenshot Archive", id: "archive") {
            ArchiveView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
