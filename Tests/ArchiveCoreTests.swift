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
    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("scan filters by prefix, age, type, and hidden files", testScanFilteringAndBoundaries),
            ("scan sorts oldest first with Finder tie-breaking", testScanOrdering),
            ("scan detects collisions including broken symlinks", testCollisions),
            ("clean refuses symlink or regular-file Archive target", testArchiveTargetValidation),
            ("clean moves candidates and skips files edited after cutoff", testCleanBasic),
            ("monthly organization routes files by modification month", testMonthlyOrganization),
            ("monthly organization refuses symlinked month folder", testMonthlySymlinkRefusal),
            ("restore undoes moves without overwriting and removes empty month dirs", testRestoreAndUndo),
            ("undo preserves a screenshot added to the same month after cleanup", testUndoWithNewArrival),
            ("hourly cleanup can be enabled, disabled and disabled again", testScheduleLifecycle),
            ("daily backup uses a separate calendar job", testBackupSchedule),
            ("S3 upload matches the AWS signature for an escaped object key", testS3Signature),
            ("backup ZIP restores current and archived screenshots", testBackupContents),
            ("empty and failed backups clean up without reporting an upload", testBackupFailure),
            ("unverified unloads preserve the schedule file and report the failure", testUnverifiedUnload),
            ("schedule status distinguishes an orphaned job, a pending plist and a lookup error", testScheduleStatus),
            ("error classification distinguishes missing folder and permission errors", testErrorClassification)
        ]

        var passed = 0
        var failed = 0

        for (name, test) in tests {
            do {
                try await test()
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

    static func testUndoWithNewArrival() throws {
        try withTempDir { dir in
            let service = ArchiveService(folder: dir, organizeByMonth: true)
            let old = isoDate("2026-10-15T12:00:00Z")
            let now = isoDate("2026-11-20T12:00:00Z")
            try makeFile(in: dir, name: "Screenshot A.png", modifiedAt: old)
            let manual = try service.clean(days: 1, now: now)
            try makeFile(in: dir, name: "Screenshot B.png", contents: "later arrival", modifiedAt: old)
            let hourly = try service.clean(days: 1, now: now)
            try expectEqual(manual.moved, 1)
            try expectEqual(hourly.moved, 1)

            let result = service.restore(manual.moves)
            try expectEqual(result.restored, 1)
            try expect(result.errors.isEmpty, "a populated month is expected during Undo")
            try expectEqual(try String(contentsOf: hourly.moves[0].destination, encoding: .utf8), "later arrival")
        }
    }

    static func testScheduleLifecycle() throws {
        try withTempDir { dir in
            let plist = dir.appendingPathComponent("agent.plist")
            var loaded = false
            let agent = LaunchAgent(plistURL: plist) { args in
                switch args.first {
                case "bootstrap":
                    loaded = true
                case "bootout":
                    guard loaded else { throw NSError(domain: LaunchAgent.label, code: 3) }
                    loaded = false
                case "print":
                    guard loaded else { throw NSError(domain: LaunchAgent.label, code: 113) }
                default:
                    throw TestFailure(description: "Unexpected launchctl arguments \(args)")
                }
            }
            try agent.setAutomatic(true)
            try expect(loaded && FileManager.default.fileExists(atPath: plist.path), "job and plist should exist")
            try expectEqual(agent.status(), .enabled)
            try agent.setAutomatic(false)
            try expect(!loaded && !FileManager.default.fileExists(atPath: plist.path), "job and plist should be gone")
            try agent.setAutomatic(false)
            try expectEqual(agent.status(), .disabled)
        }
    }

    static func testBackupSchedule() throws {
        try withTempDir { dir in
            let plist = dir.appendingPathComponent("backup.plist")
            let agent = LaunchAgent(plistURL: plist, job: .backup) { args in
                if args.first != "bootstrap" {
                    try expect(args.last?.hasSuffix("/com.jmitch.screenshot-archive.backup") == true, "wrong launchctl job")
                    throw NSError(domain: LaunchAgent.label, code: 113)
                }
            }
            try agent.setAutomatic(true)
            let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
            try expectEqual(value?["Label"] as? String, agent.job.label)
            try expectEqual(value?["StartCalendarInterval"] as? [String: Int], ["Hour": 20, "Minute": 0])
            try expectEqual((value?["ProgramArguments"] as? [String])?.last, "--backup")
            try expect(value?["RunAtLoad"] == nil && value?["StartInterval"] == nil, "unexpected backup trigger")
            try expect(LaunchAgent.current.plistURL != LaunchAgent.scheduled(.backup).plistURL, "jobs share a plist")
        }
    }

    static func testS3Signature() throws {
        var destination = BackupDestination(endpoint: "https://objects.example.test:9443/", region: "auto",
                                            bucket: "test-bucket", prefix: "/a b/é+/", accessKeyID: "example")
        let upload = S3Upload(destination: destination, secret: "example-secret")
        let hash = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        let request = try upload.request(filename: "snapshot.zip", payloadHash: hash, date: isoDate("2026-11-20T12:00:00Z"))
        try expectEqual(request.url?.absoluteString, "https://objects.example.test:9443/test-bucket/a%20b/%C3%A9%2B/snapshot.zip")
        // Signature generated independently with botocore's S3SigV4Auth.
        let signature = "0c12b93952eb85a10c03b655d121a72781a6c02a8dd4bdea2211b34b16d28174"
        let authorization = "AWS4-HMAC-SHA256 Credential=example/20261120/auto/s3/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature=" + signature
        try expectEqual(request.value(forHTTPHeaderField: "Authorization"), authorization)
        for endpoint in ["http://objects.example.test", "https://user:password@example.test", "https://example.test/?token=x"] {
            destination.endpoint = endpoint
            try expect((try? destination.validated()) == nil, "accepted invalid endpoint")
        }
    }

    static func testBackupContents() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let included = ["Screenshot new\nline.png", "Archive/Screenshot flat.png", "Archive/2026-11/Screenshot 月.png"]
        let excluded = ["private.pdf", "Archive/other.txt", "Archive/.hidden/Screenshot secret.png",
                        "Archive/other/Screenshot unrelated.png", "Screenshot folder/Screenshot nested.png"]
        for path in included + excluded {
            let url = dir.appendingPathComponent(path)
            try makeFile(in: url.deletingLastPathComponent(), name: url.lastPathComponent, contents: path, modifiedAt: Date())
        }
        try fm.createSymbolicLink(at: dir.appendingPathComponent("Screenshot link.png"), withDestinationURL: dir.appendingPathComponent("private.pdf"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("Archive/2026-10"), withDestinationURL: dir.appendingPathComponent("Archive/other"))
        let restore = dir.appendingPathComponent("restored")
        try fm.createDirectory(at: restore, withIntermediateDirectories: false)
        let summary = try await ObjectBackup(folder: dir).run { zip in
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xf", zip.path, "-C", restore.path]
            try tar.run()
            tar.waitUntilExit()
            try expectEqual(tar.terminationStatus, 0)
            let restored = try fm.subpathsOfDirectory(atPath: restore.path).filter { path in
                let info = try restore.appendingPathComponent(path).resourceValues(forKeys: [.isDirectoryKey])
                return info.isDirectory != true
            }
            try expectEqual(restored.sorted(), included.sorted())
            for path in included {
                try expectEqual(try String(contentsOf: restore.appendingPathComponent(path), encoding: .utf8), path)
            }
        }
        try expectEqual(summary, "Backed up 3 screenshots.")
    }

    static func testBackupFailure() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let backup = ObjectBackup(folder: dir)
        let empty = try await backup.run { _ in throw TestFailure(description: "attempted an empty upload") }
        try expectEqual(empty, "No screenshots to back up.")
        try makeFile(in: dir, name: "Screenshot A.png", modifiedAt: Date())
        var uploadedPath = ""
        do {
            _ = try await backup.run { zip in
                uploadedPath = zip.path
                throw BackupError("simulated upload failure")
            }
            throw TestFailure(description: "backup reported success after upload failed")
        } catch let error as BackupError {
            try expectEqual(error.message, "simulated upload failure")
        }
        try expect(!uploadedPath.isEmpty && !fm.fileExists(atPath: uploadedPath), "temporary ZIP still exists")
        try expect(fm.fileExists(atPath: dir.appendingPathComponent("Screenshot A.png").path), "source disappeared")
    }

    static func testUnverifiedUnload() throws {
        try withTempDir { dir in
            let plist = dir.appendingPathComponent("agent.plist")
            let original = Data("original schedule".utf8)
            try original.write(to: plist)
            // bootout failure, still loaded after success, and an inconclusive lookup.
            for (bootoutCode, printCode, expectedError) in [(5, 0, 5), (0, 0, Int(EBUSY)), (0, 1, 1)] {
                let agent = LaunchAgent(plistURL: plist) { args in
                    let code = args.first == "bootout" ? bootoutCode : printCode
                    if code != 0 { throw NSError(domain: LaunchAgent.label, code: code) }
                }
                do {
                    try agent.setAutomatic(false)
                    throw TestFailure(description: "Disable succeeded without confirming the job was gone")
                } catch let error as NSError where error.domain == LaunchAgent.label {
                    try expectEqual(error.code, expectedError)
                }
                try expectEqual(try Data(contentsOf: plist), original)
            }
        }
    }

    static func testScheduleStatus() throws {
        try withTempDir { dir in
            let plist = dir.appendingPathComponent("agent.plist")
            var printCode = 0
            let agent = LaunchAgent(plistURL: plist) { args in
                guard args.first == "print" else { throw NSError(domain: LaunchAgent.label, code: 3) }
                if printCode != 0 { throw NSError(domain: LaunchAgent.label, code: printCode) }
            }
            try expectEqual(agent.status(), .enabled, "a loaded job can outlive its plist")
            printCode = 1
            try expectEqual(agent.status().isEnabled, nil, "lookup failure leaves status unknown")
            try Data().write(to: plist)
            printCode = 113
            try expectEqual(agent.status(), .pendingLoad)
            try agent.setAutomatic(false)
            try expectEqual(agent.status(), .disabled)
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
