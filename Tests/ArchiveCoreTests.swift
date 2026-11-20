import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) throws {
    if !condition() {
        throw TestFailure(description: "\(file):\(line): \(message)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if actual != expected {
        let prefix = message.isEmpty ? "" : "\(message) — "
        throw TestFailure(description: "\(file):\(line): \(prefix)expected \(expected), got \(actual)")
    }
}

private func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("screenshot-archive-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

@discardableResult
private func makeFile(
    in dir: URL,
    name: String,
    contents: String = "png-data",
    modifiedAt: Date
) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    return url
}

private func isoDate(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: string)!
}

@main
struct ArchiveCoreTestRunner {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("scan filters by prefix, age, type, and hidden files", testScanFilteringAndBoundaries),
            ("scan sorts oldest first with Finder tie-breaking", testScanOrdering),
            ("scan detects collisions including broken symlinks", testCollisions),
            ("clean refuses symlink or regular-file Archive target", testArchiveTargetValidation),
            ("clean moves candidates and skips files edited after cutoff", testCleanBasic),
            ("monthly organization routes files by modification month", testMonthlyOrganization),
            ("monthly organization refuses symlinked month folder", testMonthlySymlinkRefusal),
            ("restore undoes moves without overwriting and removes empty month dirs", testRestoreAndUndo),
            ("error classification distinguishes missing folder and permission errors", testErrorClassification)
        ]

        var passed = 0
        var failed = 0

        for (name, test) in tests {
            do {
                try test()
                print("PASS  \(name)")
                passed += 1
            } catch {
                fputs("FAIL  \(name)\n      \(error)\n", stderr)
                failed += 1
            }
        }

        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func testScanFilteringAndBoundaries() throws {
        try withTempDir { dir in
            let now = isoDate("2026-11-20T12:00:00Z")
            let exactlyCutoff = now.addingTimeInterval(-3 * 86400)
            let oneSecondAfterCutoff = now.addingTimeInterval(-3 * 86400 + 1)
            let veryOld = now.addingTimeInterval(-10 * 86400)

            try makeFile(in: dir, name: "Screenshot exact.png", contents: "12345", modifiedAt: exactlyCutoff)
            try makeFile(in: dir, name: "Screenshot old.png", contents: "123", modifiedAt: veryOld)
            try makeFile(in: dir, name: "Screenshot recent.png", contents: "1", modifiedAt: oneSecondAfterCutoff)
            try makeFile(in: dir, name: "Screen Recording 2026.mov", contents: "video", modifiedAt: veryOld)
            try makeFile(in: dir, name: "Renamed capture.png", contents: "keep", modifiedAt: veryOld)
            try makeFile(in: dir, name: ".Screenshot hidden.png", contents: "hidden", modifiedAt: veryOld)

            // Subfolder starting with "Screenshot " must be ignored.
            let sub = dir.appendingPathComponent("Screenshot Folder", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

            // Symlink starting with "Screenshot " must be ignored.
            let target = try makeFile(in: dir, name: "target.png", contents: "x", modifiedAt: veryOld)
            try FileManager.default.createSymbolicLink(
                at: dir.appendingPathComponent("Screenshot symlink.png"),
                withDestinationURL: target
            )

            let service = ArchiveService(folder: dir, timeZone: TimeZone(secondsFromGMT: 0)!)
            let scan = try service.scan(days: 3, now: now)

            try expectEqual(scan.candidates.map(\.name), ["Screenshot old.png", "Screenshot exact.png"])
            try expectEqual(scan.recentCount, 1, "only Screenshot recent.png should count as recent")
            try expectEqual(scan.collisionCount, 0)
            try expectEqual(scan.bytes, 8)
        }
    }

    static func testScanOrdering() throws {
        try withTempDir { dir in
            let now = isoDate("2026-11-20T12:00:00Z")
            let older = now.addingTimeInterval(-5 * 86400)
            let sameTime = now.addingTimeInterval(-4 * 86400)

            try makeFile(in: dir, name: "Screenshot 10.png", modifiedAt: sameTime)
            try makeFile(in: dir, name: "Screenshot 2.png", modifiedAt: sameTime)
            try makeFile(in: dir, name: "Screenshot 99.png", modifiedAt: older)

            let service = ArchiveService(folder: dir)
            let scan = try service.scan(days: 1, now: now)

            try expectEqual(
                scan.candidates.map(\.name),
                ["Screenshot 99.png", "Screenshot 2.png", "Screenshot 10.png"]
            )
        }
    }

    static func testCollisions() throws {
        try withTempDir { dir in
            let now = isoDate("2026-11-20T12:00:00Z")
            let old = now.addingTimeInterval(-5 * 86400)

            try makeFile(in: dir, name: "Screenshot dup.png", modifiedAt: old)
            try makeFile(in: dir, name: "Screenshot broken.png", modifiedAt: old)
            try makeFile(in: dir, name: "Screenshot ok.png", modifiedAt: old)

            let archive = dir.appendingPathComponent("Archive", isDirectory: true)
            try makeFile(in: archive, name: "Screenshot dup.png", modifiedAt: old)
            try FileManager.default.createSymbolicLink(
                atPath: archive.appendingPathComponent("Screenshot broken.png").path,
                withDestinationPath: "/nonexistent/path/target.png"
            )

            let service = ArchiveService(folder: dir)
            let scan = try service.scan(days: 3, now: now)

            try expectEqual(scan.candidates.map(\.name), ["Screenshot ok.png"])
            try expectEqual(scan.collisionCount, 2, "both regular file and broken symlink should count as collisions")
        }
    }

    static func testArchiveTargetValidation() throws {
        try withTempDir { dir in
            let now = isoDate("2026-11-20T12:00:00Z")
            let old = now.addingTimeInterval(-5 * 86400)
            try makeFile(in: dir, name: "Screenshot one.png", modifiedAt: old)

            // Case 1: Archive is a symlink.
            let external = dir.appendingPathComponent("External", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: dir.appendingPathComponent("Archive"),
                withDestinationURL: external
            )

            let service = ArchiveService(folder: dir)
            do {
                _ = try service.clean(days: 1, now: now)
                throw TestFailure(description: "Expected archiveIsSymlink error")
            } catch let error as ArchiveError {
                try expectEqual(error, .archiveIsSymlink)
            }

            // Case 2: Archive is a regular file.
            try FileManager.default.removeItem(at: dir.appendingPathComponent("Archive"))
            try makeFile(in: dir, name: "Archive", contents: "not a folder", modifiedAt: old)

            do {
                _ = try service.clean(days: 1, now: now)
                throw TestFailure(description: "Expected archiveIsNotDirectory error")
            } catch let error as ArchiveError {
                try expectEqual(error, .archiveIsNotDirectory)
            }
        }
    }

    static func testCleanBasic() throws {
        try withTempDir { dir in
            let now = isoDate("2026-11-20T12:00:00Z")
            let old = now.addingTimeInterval(-4 * 86400)
            let recent = now.addingTimeInterval(-1 * 86400)

            let oldFile = try makeFile(in: dir, name: "Screenshot old.png", modifiedAt: old)
            let recentFile = try makeFile(in: dir, name: "Screenshot recent.png", modifiedAt: recent)

            let service = ArchiveService(folder: dir)
            let result = try service.clean(days: 3, now: now)

            try expectEqual(result.moved, 1)
            try expect(result.errors.isEmpty, "expected no errors")
            try expect(!FileManager.default.fileExists(atPath: oldFile.path), "old file should be moved")
            try expect(FileManager.default.fileExists(atPath: service.archive.appendingPathComponent("Screenshot old.png").path), "old file should be in Archive")
            try expect(FileManager.default.fileExists(atPath: recentFile.path), "recent file should stay put")
        }
    }

    static func testMonthlyOrganization() throws {
        try withTempDir { dir in
            let now = isoDate("2026-11-20T12:00:00Z")
            let octDate = isoDate("2026-10-15T18:30:00Z")
            let novDate = isoDate("2026-11-02T09:00:00Z")

            try makeFile(in: dir, name: "Screenshot oct.png", modifiedAt: octDate)
            try makeFile(in: dir, name: "Screenshot nov.png", modifiedAt: novDate)

            let service = ArchiveService(folder: dir, organizeByMonth: true, timeZone: TimeZone(secondsFromGMT: 0)!)
            let result = try service.clean(days: 3, now: now)

            try expectEqual(result.moved, 2)
            try expect(result.errors.isEmpty, "expected no errors")
            try expect(
                FileManager.default.fileExists(atPath: service.archive.appendingPathComponent("2026-10/Screenshot oct.png").path),
                "October file should be in Archive/2026-10"
            )
            try expect(
                FileManager.default.fileExists(atPath: service.archive.appendingPathComponent("2026-11/Screenshot nov.png").path),
                "November file should be in Archive/2026-11"
            )
        }
    }

    static func testMonthlySymlinkRefusal() throws {
        try withTempDir { dir in
            let now = isoDate("2026-11-20T12:00:00Z")
            let octDate = isoDate("2026-10-15T18:30:00Z")

            let file = try makeFile(in: dir, name: "Screenshot oct.png", modifiedAt: octDate)
            let archive = dir.appendingPathComponent("Archive", isDirectory: true)
            let external = dir.appendingPathComponent("External", isDirectory: true)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: archive.appendingPathComponent("2026-10"),
                withDestinationURL: external
            )

            let service = ArchiveService(folder: dir, organizeByMonth: true, timeZone: TimeZone(secondsFromGMT: 0)!)
            let result = try service.clean(days: 3, now: now)

            try expectEqual(result.moved, 0)
            try expectEqual(result.errors.count, 1)
            try expect(FileManager.default.fileExists(atPath: file.path), "file should not be moved through symlinked month folder")
        }
    }

    static func testRestoreAndUndo() throws {
        try withTempDir { dir in
            let now = isoDate("2026-11-20T12:00:00Z")
            let octDate = isoDate("2026-10-15T18:30:00Z")
            let novDate = isoDate("2026-11-02T09:00:00Z")

            let fileA = try makeFile(in: dir, name: "Screenshot A.png", contents: "original-A", modifiedAt: octDate)
            let fileB = try makeFile(in: dir, name: "Screenshot B.png", contents: "original-B", modifiedAt: novDate)

            // Pre-existing archived file in 2026-11 so 2026-11 remains non-empty after restore.
            let archive = dir.appendingPathComponent("Archive", isDirectory: true)
            try makeFile(in: archive.appendingPathComponent("2026-11", isDirectory: true), name: "Screenshot earlier.png", modifiedAt: novDate)

            let service = ArchiveService(folder: dir, organizeByMonth: true, timeZone: TimeZone(secondsFromGMT: 0)!)
            let cleanResult = try service.clean(days: 3, now: now)
            try expectEqual(cleanResult.moved, 2)

            // Create a new file at fileB's original path so restore must skip it instead of overwriting.
            try makeFile(in: dir, name: "Screenshot B.png", contents: "replacement-B", modifiedAt: now)

            let restoreResult = service.restore(cleanResult.moves)
            try expectEqual(restoreResult.restored, 1)
            try expectEqual(restoreResult.skipped, 1)
            try expect(restoreResult.errors.isEmpty, "expected no restore errors")

            try expectEqual(try String(contentsOf: fileA, encoding: .utf8), "original-A")
            try expectEqual(try String(contentsOf: fileB, encoding: .utf8), "replacement-B")
            try expect(!FileManager.default.fileExists(atPath: archive.appendingPathComponent("2026-10").path), "empty month folder should be cleaned up")
            try expect(FileManager.default.fileExists(atPath: archive.appendingPathComponent("2026-11/Screenshot earlier.png").path), "non-empty month folder should stay")
        }
    }

    static func testErrorClassification() throws {
        let missingCocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        let missingPosix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        let permCocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let permPosix = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let wrappedPerm = NSError(domain: NSCocoaErrorDomain, code: 0, userInfo: [NSUnderlyingErrorKey: permPosix])

        try expect(ArchiveService.isMissingFolderError(missingCocoa), "Cocoa ENOENT")
        try expect(ArchiveService.isMissingFolderError(missingPosix), "POSIX ENOENT")
        try expect(!ArchiveService.isPermissionError(missingCocoa), "missing is not permission")

        try expect(ArchiveService.isPermissionError(permCocoa), "Cocoa EPERM")
        try expect(ArchiveService.isPermissionError(permPosix), "POSIX EPERM")
        try expect(ArchiveService.isPermissionError(wrappedPerm), "wrapped POSIX EPERM")
    }
}
