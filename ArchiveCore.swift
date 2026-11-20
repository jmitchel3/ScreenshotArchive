import Darwin
import Foundation

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
}

struct ArchiveScan: Sendable {
    var candidates: [ArchiveCandidate] = []
    var recentCount = 0
    var collisionCount = 0
    var bytes: Int64 = 0
}

struct ArchiveResult: Sendable {
    var moves: [ArchiveMove] = []
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

struct ArchiveService: Sendable {
    let folder: URL
    let organizeByMonth: Bool
    let timeZone: TimeZone

    var archive: URL { folder.appendingPathComponent("Archive", isDirectory: true) }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .contentModificationDateKey,
        .fileSizeKey
    ]

    init(folder: URL, organizeByMonth: Bool = false, timeZone: TimeZone = .current) {
        self.folder = folder
        self.organizeByMonth = organizeByMonth
        self.timeZone = timeZone
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

    static func isScreenshot(_ name: String) -> Bool { name.hasPrefix("Screenshot ") }

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
            guard Self.isScreenshot(file.lastPathComponent) else { continue }
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
                    let subdirInfo = try? destDir.resourceValues(forKeys: [.isSymbolicLinkKey])
                    if subdirInfo?.isSymbolicLink == true {
                        throw ArchiveError.subfolderIsSymlink(destDir.lastPathComponent)
                    }
                    try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                }

                let target = destDir.appendingPathComponent(fresh.lastPathComponent)
                // FileManager refuses to overwrite an existing destination.
                try fm.moveItem(at: fresh, to: target)
                result.moves.append(ArchiveMove(source: fresh, destination: target))
            } catch {
                result.errors.append("\(candidate.name): \(error.localizedDescription)")
            }
        }
        return result
    }

    func restore(_ moves: [ArchiveMove]) -> ArchiveRestoreResult {
        let fm = FileManager.default
        var result = ArchiveRestoreResult()
        var touchedSubdirs: Set<URL> = []

        for move in moves.reversed() {
            guard (try? fm.attributesOfItem(atPath: move.destination.path)) != nil else {
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
                let parent = move.destination.deletingLastPathComponent().standardizedFileURL
                let archiveRoot = archive.standardizedFileURL
                if parent != archiveRoot, parent.path.hasPrefix(archiveRoot.path + "/") {
                    touchedSubdirs.insert(parent)
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
