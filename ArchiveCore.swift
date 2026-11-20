import Darwin
import Foundation

struct FileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64

    static func of(path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
    }
}

struct ArchiveCandidate: Identifiable, Hashable, Sendable {
    let url: URL
    let modifiedAt: Date
    let size: Int64

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct ArchiveMove: Hashable, Sendable {
    let source: URL
    let destination: URL
    let fileIdentity: FileIdentity?

    init(source: URL, destination: URL, fileIdentity: FileIdentity? = nil) {
        self.source = source
        self.destination = destination
        self.fileIdentity = fileIdentity
    }
}

struct ArchiveScan: Sendable {
    var candidates: [ArchiveCandidate] = []
    var recentCount = 0
    var collisionCount = 0
    var bytes: Int64 = 0
}

struct ArchiveStats: Equatable, Sendable {
    var fileCount = 0
    var allocatedBytes: Int64 = 0
    var flatMatchingCount = 0
    var partial = false
}

struct ArchiveResult: Sendable {
    var moves: [ArchiveMove] = []
    var errors: [String] = []

    var moved: Int { moves.count }
}

struct ArchiveOrganizeResult: Sendable {
    var moves: [ArchiveMove] = []
    var skippedCollisions = 0
    var errors: [String] = []

    var moved: Int { moves.count }
}

struct ArchiveRestoreResult: Sendable {
    var restored = 0
    var skipped = 0
    var errors: [String] = []
}

enum ArchiveError: LocalizedError, Equatable, Sendable {
    case archiveIsSymlink
    case archiveIsNotDirectory
    case subfolderIsSymlink(String)

    var errorDescription: String? {
        switch self {
        case .archiveIsSymlink:
            return "Archive must be a folder, not a symbolic link."
        case .archiveIsNotDirectory:
            return "Archive already exists as a file instead of a folder."
        case .subfolderIsSymlink(let name):
            return "Archive/\(name) must be a folder, not a symbolic link."
        }
    }
}

enum KeepRenameError: LocalizedError, Equatable, Sendable {
    case emptyName
    case invalidCharacters
    case stillMatchesScreenshotPrefix(String)
    case destinationExists
    case sourceNotRegularFile

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Enter a name for this screenshot."
        case .invalidCharacters:
            return "File names cannot contain slashes, colons, or path segments like '.' or '..'."
        case .stillMatchesScreenshotPrefix(let prefix):
            return "Choose a name that does not start with \"\(prefix)\" so it stays out of Archive."
        case .destinationExists:
            return "A file with that name already exists in this folder."
        case .sourceNotRegularFile:
            return "This file is no longer available as a regular file."
        }
    }
}

enum FailureCategory: String, Equatable, Sendable {
    case permission
    case missingFolder
    case archiveInvalid
    case partialFailure
    case other

    static func classify(_ error: Error) -> FailureCategory {
        if ArchiveService.isPermissionError(error) { return .permission }
        if ArchiveService.isMissingFolderError(error) { return .missingFolder }
        if error is ArchiveError { return .archiveInvalid }
        return .other
    }
}

struct FailureNotificationState: Equatable, Sendable {
    var lastCategory: String?
    var lastSentAt: Date?
}

enum FailureNotificationPolicy {
    static let defaultCooldown: TimeInterval = 6 * 3600

    static func shouldNotify(
        category: FailureCategory,
        state: FailureNotificationState,
        now: Date = Date(),
        cooldown: TimeInterval = defaultCooldown
    ) -> Bool {
        guard state.lastCategory == category.rawValue, let lastSentAt = state.lastSentAt else {
            return true
        }
        return now.timeIntervalSince(lastSentAt) >= cooldown
    }

    static func notificationBody(for category: FailureCategory, failedCount: Int = 0) -> String {
        switch category {
        case .permission:
            return "Automatic cleanup needs folder permission. Open Screenshot Archive to review access."
        case .missingFolder:
            return "The configured screenshots folder was not found. Open Screenshot Archive to choose a folder."
        case .archiveInvalid:
            return "Automatic cleanup could not use the Archive folder. Open Screenshot Archive for details."
        case .partialFailure:
            if failedCount > 0 {
                return "Automatic cleanup could not move \(failedCount) screenshot\(failedCount == 1 ? "" : "s"). Open Screenshot Archive for details."
            }
            return "Automatic cleanup finished with errors. Open Screenshot Archive for details."
        case .other:
            return "Automatic cleanup failed. Open Screenshot Archive for details."
        }
    }
}

struct ArchiveService: Sendable {
    static let defaultPrefix = "Screenshot"
    static let supportedCaptureExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp", "pdf", "webp"
    ]

    let folder: URL
    let organizeByMonth: Bool
    let screenshotPrefix: String
    let timeZone: TimeZone

    var archive: URL { folder.appendingPathComponent("Archive", isDirectory: true) }

    var archiveMatchingPrefixes: [String] {
        let active = Self.normalizedPrefix(screenshotPrefix)
        if active == Self.defaultPrefix { return [active] }
        return [active, Self.defaultPrefix]
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .contentModificationDateKey,
        .fileSizeKey
    ]

    private static let statsResourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey
    ]

    init(
        folder: URL,
        organizeByMonth: Bool = false,
        screenshotPrefix: String = ArchiveService.defaultPrefix,
        timeZone: TimeZone = .current
    ) {
        self.folder = folder
        self.organizeByMonth = organizeByMonth
        self.screenshotPrefix = Self.normalizedPrefix(screenshotPrefix)
        self.timeZone = timeZone
    }

    static func normalizedPrefix(_ raw: String?) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return defaultPrefix
        }
        return trimmed
    }

    static func detectedPrefix(userDefaults: UserDefaults? = UserDefaults(suiteName: "com.apple.screencapture")) -> String {
        normalizedPrefix(userDefaults?.string(forKey: "name"))
    }

    static func isScreenshot(_ name: String, prefix: String = defaultPrefix) -> Bool {
        isScreenshot(name, prefixes: [prefix])
    }

    static func isScreenshot(_ name: String, prefixes: [String]) -> Bool {
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }
        let fileURL = URL(fileURLWithPath: name)
        let ext = fileURL.pathExtension.lowercased()
        guard supportedCaptureExtensions.contains(ext) else { return false }
        let stem = fileURL.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { return false }

        for rawPrefix in prefixes {
            let prefix = normalizedPrefix(rawPrefix)
            if stem == prefix || stem.hasPrefix(prefix + " ") {
                return true
            }
        }
        return false
    }

    func monthFolderName(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    func destinationDirectory(for modifiedDate: Date) -> URL {
        if organizeByMonth {
            return archive.appendingPathComponent(monthFolderName(for: modifiedDate), isDirectory: true)
        }
        return archive
    }

    func destination(for file: URL, modifiedDate: Date) -> URL {
        destinationDirectory(for: modifiedDate).appendingPathComponent(file.lastPathComponent)
    }

    func scan(days: Int, now: Date = Date()) throws -> ArchiveScan {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86400)
        let files = try fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: [.skipsHiddenFiles]
        )

        var result = ArchiveScan()
        for file in files {
            guard Self.isScreenshot(file.lastPathComponent, prefix: screenshotPrefix) else { continue }
            guard let info = try? file.resourceValues(forKeys: Self.resourceKeys) else { continue }
            guard info.isRegularFile == true, info.isSymbolicLink != true else { continue }
            guard let modified = info.contentModificationDate, modified <= cutoff else {
                result.recentCount += 1
                continue
            }

            let target = destination(for: file, modifiedDate: modified)
            if (try? fm.attributesOfItem(atPath: target.path)) != nil {
                result.collisionCount += 1
                continue
            }

            let size = Int64(info.fileSize ?? 0)
            result.candidates.append(ArchiveCandidate(url: file, modifiedAt: modified, size: size))
            result.bytes += size
        }

        result.candidates.sort { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt < rhs.modifiedAt
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return result
    }

    func archiveStats() -> ArchiveStats {
        let fm = FileManager.default
        guard let rootAttrs = try? fm.attributesOfItem(atPath: archive.path) else {
            return ArchiveStats()
        }
        guard (rootAttrs[.type] as? FileAttributeType) == .typeDirectory else {
            return ArchiveStats(partial: true)
        }

        var stats = ArchiveStats()
        let prefixes = archiveMatchingPrefixes

        func walk(_ directory: URL, isTopLevel: Bool) {
            let entries: [URL]
            do {
                entries = try fm.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Array(Self.statsResourceKeys),
                    options: [.skipsHiddenFiles]
                )
            } catch {
                stats.partial = true
                return
            }

            for entry in entries {
                guard let info = try? entry.resourceValues(forKeys: Self.statsResourceKeys) else {
                    stats.partial = true
                    continue
                }
                guard info.isSymbolicLink != true else { continue }
                if info.isDirectory == true {
                    walk(entry, isTopLevel: false)
                } else if info.isRegularFile == true {
                    stats.fileCount += 1
                    let allocated = info.totalFileAllocatedSize ?? info.fileAllocatedSize ?? info.fileSize ?? 0
                    stats.allocatedBytes += Int64(allocated)
                    if isTopLevel && Self.isScreenshot(entry.lastPathComponent, prefixes: prefixes) {
                        stats.flatMatchingCount += 1
                    }
                }
            }
        }

        walk(archive, isTopLevel: true)
        return stats
    }

    func clean(days: Int, now: Date = Date()) throws -> ArchiveResult {
        let fm = FileManager.default
        let scanResult = try scan(days: days, now: now)
        var result = ArchiveResult()
        guard !scanResult.candidates.isEmpty else { return result }

        try validateArchiveDirectory(fm: fm)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)

        let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86400)
        for candidate in scanResult.candidates {
            do {
                // Re-read metadata in case the screenshot was edited or removed after scanning.
                let fresh = URL(fileURLWithPath: candidate.url.path)
                let info: URLResourceValues
                do {
                    info = try fresh.resourceValues(forKeys: Self.resourceKeys)
                } catch {
                    if Self.isMissingFolderError(error) { continue }
                    throw error
                }
                guard info.isRegularFile == true, info.isSymbolicLink != true,
                      let modified = info.contentModificationDate, modified <= cutoff else { continue }

                let destDir = destinationDirectory(for: modified)
                if organizeByMonth {
                    try validateMonthSubdirectory(destDir, fm: fm)
                    try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                }

                let identity = FileIdentity.of(path: fresh.path)
                let target = destDir.appendingPathComponent(fresh.lastPathComponent)
                // FileManager refuses to overwrite an existing destination.
                try fm.moveItem(at: fresh, to: target)
                result.moves.append(ArchiveMove(source: fresh, destination: target, fileIdentity: identity))
            } catch {
                result.errors.append("\(candidate.name): \(error.localizedDescription)")
            }
        }
        return result
    }

    func organizeArchive() throws -> ArchiveOrganizeResult {
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: archive.path)) != nil else {
            return ArchiveOrganizeResult()
        }
        try validateArchiveDirectory(fm: fm)

        let entries = try fm.contentsOfDirectory(
            at: archive,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: [.skipsHiddenFiles]
        )
        let prefixes = archiveMatchingPrefixes
        var result = ArchiveOrganizeResult()

        for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard Self.isScreenshot(entry.lastPathComponent, prefixes: prefixes) else { continue }
            do {
                let fresh = URL(fileURLWithPath: entry.path)
                let info: URLResourceValues
                do {
                    info = try fresh.resourceValues(forKeys: Self.resourceKeys)
                } catch {
                    if Self.isMissingFolderError(error) { continue }
                    throw error
                }
                guard info.isRegularFile == true, info.isSymbolicLink != true,
                      let modified = info.contentModificationDate else { continue }

                let monthDir = archive.appendingPathComponent(monthFolderName(for: modified), isDirectory: true)
                try validateMonthSubdirectory(monthDir, fm: fm)
                let target = monthDir.appendingPathComponent(fresh.lastPathComponent)

                if (try? fm.attributesOfItem(atPath: target.path)) != nil {
                    result.skippedCollisions += 1
                    continue
                }

                try fm.createDirectory(at: monthDir, withIntermediateDirectories: true)
                let identity = FileIdentity.of(path: fresh.path)
                try fm.moveItem(at: fresh, to: target)
                result.moves.append(ArchiveMove(source: fresh, destination: target, fileIdentity: identity))
            } catch {
                result.errors.append("\(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    func renameToKeep(_ url: URL, newStem: String) throws -> URL {
        let fm = FileManager.default
        let trimmed = newStem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeepRenameError.emptyName }
        guard trimmed != ".", trimmed != "..",
              trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)) == nil else {
            throw KeepRenameError.invalidCharacters
        }

        let source = URL(fileURLWithPath: url.path)
        guard source.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else {
            throw KeepRenameError.sourceNotRegularFile
        }
        guard let info = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              info.isRegularFile == true, info.isSymbolicLink != true else {
            throw KeepRenameError.sourceNotRegularFile
        }

        let ext = source.pathExtension
        let finalName = ext.isEmpty ? trimmed : "\(trimmed).\(ext)"
        if Self.isScreenshot(finalName, prefix: screenshotPrefix) {
            throw KeepRenameError.stillMatchesScreenshotPrefix(screenshotPrefix)
        }

        let target = folder.appendingPathComponent(finalName)
        if (try? fm.attributesOfItem(atPath: target.path)) != nil {
            throw KeepRenameError.destinationExists
        }

        try fm.moveItem(at: source, to: target)
        return target
    }

    func restore(_ moves: [ArchiveMove]) -> ArchiveRestoreResult {
        let fm = FileManager.default
        var result = ArchiveRestoreResult()
        var touchedSubdirs: Set<URL> = []
        let archiveRoot = archive.standardizedFileURL

        for move in moves.reversed() {
            do {
                try validateArchiveDirectory(fm: fm)
            } catch {
                result.errors.append(error.localizedDescription)
                return result
            }

            let destParent = move.destination.deletingLastPathComponent().standardizedFileURL
            if destParent != archiveRoot, destParent.path.hasPrefix(archiveRoot.path + "/") {
                if (try? validateMonthSubdirectory(destParent, fm: fm)) == nil {
                    result.skipped += 1
                    continue
                }
            }

            guard let destAttrs = try? fm.attributesOfItem(atPath: move.destination.path),
                  (destAttrs[.type] as? FileAttributeType) == .typeRegular else {
                result.skipped += 1
                continue
            }
            if let expectedID = move.fileIdentity,
               FileIdentity.of(path: move.destination.path) != expectedID {
                result.skipped += 1
                continue
            }

            let sourceParent = move.source.deletingLastPathComponent().standardizedFileURL
            if let parentAttrs = try? fm.attributesOfItem(atPath: sourceParent.path),
               (parentAttrs[.type] as? FileAttributeType) != .typeDirectory {
                result.skipped += 1
                continue
            }

            if (try? fm.attributesOfItem(atPath: move.source.path)) != nil {
                result.skipped += 1
                continue
            }

            do {
                try fm.moveItem(at: move.destination, to: move.source)
                result.restored += 1
                if destParent != archiveRoot, destParent.path.hasPrefix(archiveRoot.path + "/") {
                    touchedSubdirs.insert(destParent)
                }
            } catch {
                result.errors.append("\(move.destination.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // rmdir checks emptiness at removal time, even if another cleanup is archiving files.
        for dir in touchedSubdirs {
            _ = rmdir(fm.fileSystemRepresentation(withPath: dir.path))
        }

        return result
    }

    private func validateArchiveDirectory(fm: FileManager) throws {
        guard let attrs = try? fm.attributesOfItem(atPath: archive.path) else { return }
        let fileType = attrs[.type] as? FileAttributeType
        if fileType == .typeSymbolicLink {
            throw ArchiveError.archiveIsSymlink
        }
        if fileType != .typeDirectory {
            throw ArchiveError.archiveIsNotDirectory
        }
    }

    private func validateMonthSubdirectory(_ dir: URL, fm: FileManager) throws {
        guard let attrs = try? fm.attributesOfItem(atPath: dir.path) else { return }
        let fileType = attrs[.type] as? FileAttributeType
        if fileType == .typeSymbolicLink {
            throw ArchiveError.subfolderIsSymlink(dir.lastPathComponent)
        }
        if fileType != .typeDirectory {
            throw ArchiveError.archiveIsNotDirectory
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionError(underlying)
        }
        return false
    }

    static func isMissingFolderError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(ENOENT) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isMissingFolderError(underlying)
        }
        return false
    }
}
