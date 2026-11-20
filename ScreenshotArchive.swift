import SwiftUI
import AppKit

enum LaunchAgentStatus: Equatable, Sendable {
    case disabled
    case enabled
    case stalePath(installedPath: String)

    var isEnabled: Bool {
        switch self {
        case .enabled, .stalePath: return true
        case .disabled: return false
        }
    }
}

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
    static let label = "com.jmitch.screenshot-archive"
    static let daysKey = "archiveDays"
    static let organizeByMonthKey = "organizeByMonth"
    static let customFolderKey = "customFolderPath"
    static let lastAutoRunDateKey = "lastAutoRunDate"
    static let lastAutoRunMovedKey = "lastAutoRunMoved"
    static let lastAutoRunErrorKey = "lastAutoRunError"

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

    static var folder: URL {
        get {
            if let custom = UserDefaults.standard.string(forKey: customFolderKey), !custom.isEmpty {
                return URL(fileURLWithPath: custom, isDirectory: true)
            }
            return defaultFolder
        }
        set {
            if newValue.standardizedFileURL == defaultFolder.standardizedFileURL {
                UserDefaults.standard.removeObject(forKey: customFolderKey)
            } else {
                UserDefaults.standard.set(newValue.path, forKey: customFolderKey)
            }
        }
    }

    static var hasCustomFolder: Bool {
        UserDefaults.standard.string(forKey: customFolderKey) != nil
    }

    static var agent: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
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

    @discardableResult
    static func launchctl(_ arguments: [String], allowFailure: Bool = false) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 && !allowFailure {
            let message = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: label,
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: (message?.isEmpty == false ? message! : "Could not update automatic cleanup.")]
            )
        }
        return process.terminationStatus
    }

    static func installedAgentAppPath() -> String? {
        guard let data = try? Data(contentsOf: agent),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              let appFlagIndex = args.firstIndex(of: "-a"),
              args.indices.contains(appFlagIndex + 1) else {
            return nil
        }
        return args[appFlagIndex + 1]
    }

    static func agentStatus() -> LaunchAgentStatus {
        guard FileManager.default.fileExists(atPath: agent.path) else {
            return .disabled
        }
        guard (try? launchctl(["print", "gui/\(getuid())/\(label)"], allowFailure: true)) == 0 else {
            return .disabled
        }
        let currentPath = Bundle.main.bundleURL.standardizedFileURL.path
        if let installed = installedAgentAppPath() {
            let normalizedInstalled = URL(fileURLWithPath: installed).standardizedFileURL.path
            if normalizedInstalled != currentPath {
                return .stalePath(installedPath: installed)
            }
        }
        return .enabled
    }

    static func setAutomatic(_ enabled: Bool) throws {
        let domain = "gui/\(getuid())"
        _ = try launchctl(["bootout", "\(domain)/\(label)"], allowFailure: true)
        if enabled {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [
                    "/usr/bin/open", "-g", "-W", "-n", "-a",
                    Bundle.main.bundleURL.path,
                    "--args", "--background"
                ],
                "RunAtLoad": true,
                "StartInterval": 3600,
                "ProcessType": "Background",
                "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "com.jmitch.screenshot-archive.helper"]
            ]
            try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agent, options: .atomic)
            do {
                try launchctl(["bootstrap", domain, agent.path])
            } catch {
                try? FileManager.default.removeItem(at: agent)
                throw error
            }
        } else if FileManager.default.fileExists(atPath: agent.path) {
            try FileManager.default.removeItem(at: agent)
        }
    }
}

@MainActor
final class ArchiveModel: ObservableObject {
    @Published var scan = ArchiveScan()
    @Published var agentStatus: LaunchAgentStatus = .disabled
    @Published var lastAutoRun: AutoRunStatus? = Settings.lastAutoRun
    @Published var days: Int = Settings.days
    @Published var organizeByMonth: Bool = Settings.organizeByMonth
    @Published var folder: URL = Settings.folder
    @Published var message = ""
    @Published var problem: ProblemKind?
    @Published var lastMoves: [ArchiveMove] = []
    @Published var isBusy = false
    @Published var isUpdatingSchedule = false

    private var refreshTask: Task<Void, Never>?

    var service: ArchiveService {
        ArchiveService(folder: folder, organizeByMonth: organizeByMonth)
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

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Select"
        panel.message = "Choose the folder where macOS saves your screenshots."
        if panel.runModal() == .OK, let selected = panel.url {
            folder = selected
            Settings.folder = selected
            lastMoves = []
            message = ""
            refresh()
        }
    }

    func resetDefaultFolder() {
        let defaultURL = Settings.defaultFolder
        folder = defaultURL
        Settings.folder = defaultURL
        lastMoves = []
        message = ""
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        let currentService = service
        let currentDays = days

        refreshTask = Task {
            isBusy = true
            defer { isBusy = false }

            let outcome = await Task.detached(priority: .userInitiated) { () -> (Result<ArchiveScan, Error>, LaunchAgentStatus) in
                let scanResult = Result { try currentService.scan(days: currentDays) }
                let status = Settings.agentStatus()
                return (scanResult, status)
            }.value

            guard !Task.isCancelled else { return }

            switch outcome.0 {
            case .success(let newScan):
                scan = newScan
                problem = nil
            case .failure(let error):
                scan = ArchiveScan()
                problem = classifyError(error, folder: currentService.folder)
            }
            agentStatus = outcome.1
            lastAutoRun = Settings.lastAutoRun
        }
    }

    func clean() {
        guard !isBusy else { return }
        let currentService = service
        let currentDays = days

        Task {
            isBusy = true
            defer { isBusy = false }

            let cleanResult = await Task.detached(priority: .userInitiated) {
                Result { try currentService.clean(days: currentDays) }
            }.value

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

    func undoLastClean() {
        guard !isBusy, !lastMoves.isEmpty else { return }
        let movesToRestore = lastMoves
        let currentService = service

        Task {
            isBusy = true
            defer { isBusy = false }

            let result = await Task.detached(priority: .userInitiated) {
                currentService.restore(movesToRestore)
            }.value

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
        Task {
            isUpdatingSchedule = true
            defer { isUpdatingSchedule = false }

            let outcome = await Task.detached(priority: .userInitiated) { () -> (Error?, LaunchAgentStatus) in
                do {
                    try Settings.setAutomatic(enabled)
                    return (nil, Settings.agentStatus())
                } catch {
                    return (error, Settings.agentStatus())
                }
            }.value

            agentStatus = outcome.1
            lastAutoRun = Settings.lastAutoRun
            if let error = outcome.0 {
                problem = .general(error.localizedDescription)
            } else {
                problem = nil
                message = enabled ? "Automatic cleanup is on. Checks every hour." : "Automatic cleanup is off."
                if enabled {
                    // Refresh shortly after launchctl RunAtLoad triggers a background run.
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    refresh()
                }
            }
        }
    }

    func openArchive() {
        do {
            try FileManager.default.createDirectory(at: service.archive, withIntermediateDirectories: true)
            NSWorkspace.shared.open(service.archive)
        } catch {
            problem = classifyError(error, folder: service.archive)
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
        let currentService = service
        let currentDays = days
        let outcome = await Task.detached(priority: .userInitiated) { () -> (Result<ArchiveScan, Error>, LaunchAgentStatus) in
            let scanResult = Result { try currentService.scan(days: currentDays) }
            let status = Settings.agentStatus()
            return (scanResult, status)
        }.value

        switch outcome.0 {
        case .success(let newScan):
            scan = newScan
            if !preserveError { problem = nil }
        case .failure(let error):
            scan = ArchiveScan()
            problem = classifyError(error, folder: currentService.folder)
        }
        agentStatus = outcome.1
        lastAutoRun = Settings.lastAutoRun
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

struct ArchiveView: View {
    @StateObject private var model = ArchiveModel()
    @State private var showingFiles = false

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
        .frame(width: 440)
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

                    if Settings.hasCustomFolder {
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                        Button("Reset", action: model.resetDefaultFolder)
                            .buttonStyle(.link)
                            .font(.caption)
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

            if model.scan.collisionCount > 0 {
                Text("\(model.scan.collisionCount) skipped because the name is already in Archive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.scan.candidates.isEmpty {
                DisclosureGroup("Preview files", isExpanded: $showingFiles) {
                    let rowHeight: CGFloat = 28
                    let listHeight = min(max(36, CGFloat(model.scan.candidates.count) * rowHeight + 8), 160)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(model.scan.candidates) { candidate in
                                HStack(spacing: 8) {
                                    Text(candidate.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(candidate.name)
                                    Spacer(minLength: 8)
                                    Text("\(Self.relativeFormatter.localizedString(for: candidate.modifiedAt, relativeTo: Date())) · \(ByteCountFormatter.string(fromByteCount: candidate.size, countStyle: .file))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                    Button {
                                        model.revealInFinder(candidate.url)
                                    } label: {
                                        Image(systemName: "magnifyingglass")
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Reveal in Finder")
                                }
                                .frame(height: 24)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                    }
                    .frame(height: listHeight)
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

            Toggle("Organize Archive into YYYY-MM folders", isOn: Binding(
                get: { model.organizeByMonth },
                set: { model.updateOrganizeByMonth($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle("Clean up automatically every hour", isOn: Binding(
                get: { model.agentStatus.isEnabled },
                set: { model.setAutomatic($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(model.isUpdatingSchedule)

            if case .stalePath = model.agentStatus {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("App moved since schedule was enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Update Schedule") {
                        model.setAutomatic(true)
                    }
                    .controlSize(.small)
                }
            }

            if let lastRun = model.lastAutoRun {
                HStack(spacing: 6) {
                    if let error = lastRun.error {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text("Last auto run failed \(Self.relativeFormatter.localizedString(for: lastRun.date, relativeTo: Date())): \(error)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    } else {
                        let summary = lastRun.moved == 0 ? "all tidy" : "moved \(lastRun.moved)"
                        Text("Last auto check \(Self.relativeFormatter.localizedString(for: lastRun.date, relativeTo: Date())) (\(summary))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Log", action: model.openLogFile)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            Text("Moves screenshots unchanged for \(model.days) day\(model.days == 1 ? "" : "s") into \(model.organizeByMonth ? "Archive/YYYY-MM" : "Archive"). Rename a file without the Screenshot prefix to keep it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var feedbackSection: some View {
        if let problem = model.problem {
            VStack(alignment: .leading, spacing: 8) {
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
                }
            }
        } else if !model.message.isEmpty {
            HStack(spacing: 10) {
                Text(model.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.lastMoves.isEmpty {
                    Button("Undo", action: model.undoLastClean)
                        .controlSize(.small)
                        .disabled(model.isBusy)
                }
            }
        }
    }

    private var footerSection: some View {
        HStack {
            Button("Open Archive", action: model.openArchive)
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
        if CommandLine.arguments.contains("--background") {
            let service = ArchiveService(
                folder: Settings.folder,
                organizeByMonth: Settings.organizeByMonth
            )
            do {
                let result = try service.clean(days: Settings.days)
                let errorSummary = result.errors.isEmpty ? nil : result.errors.joined(separator: "; ")
                Settings.recordAutoRun(moved: result.moved, error: errorSummary)
                if result.moved > 0 || errorSummary != nil {
                    let suffix = errorSummary.map { " Errors: \($0)" } ?? ""
                    Settings.log("Automatic cleanup: moved \(result.moved) screenshot\(result.moved == 1 ? "" : "s").\(suffix)")
                }
                exit(result.errors.isEmpty ? 0 : 1)
            } catch {
                Settings.recordAutoRun(moved: 0, error: error.localizedDescription)
                Settings.log("Automatic cleanup failed: \(error.localizedDescription)")
                exit(1)
            }
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
