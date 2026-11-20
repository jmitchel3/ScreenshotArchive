import Foundation

enum LaunchAgentStatus: Equatable, Sendable {
    case disabled
    case enabled
    case pendingLoad
    case unavailable(String)
    case stalePath(installedPath: String)

    var isEnabled: Bool? {
        switch self {
        case .enabled, .pendingLoad, .stalePath: return true
        case .disabled: return false
        case .unavailable: return nil
        }
    }

    var repairMessage: String? {
        switch self {
        case .stalePath: return "App moved since schedule was enabled."
        case .pendingLoad: return "The schedule is configured but isn't loaded."
        default: return nil
        }
    }
}

struct LaunchAgent {
    enum Job {
        case cleanup, backup

        var label: String { self == .cleanup ? LaunchAgent.label : LaunchAgent.label + ".backup" }
    }

    static let label = "com.jmitch.screenshot-archive"
    // launchctl's service lookup error (launchctl error 113).
    private static let serviceNotFound = 113

    let plistURL: URL
    var job: Job = .cleanup
    var launchctl: ([String]) throws -> Void = runLaunchctl

    static var current: LaunchAgent {
        scheduled(.cleanup)
    }

    static func scheduled(_ job: Job) -> LaunchAgent {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(job.label).plist")
        return LaunchAgent(plistURL: plist, job: job)
    }

    private var domain: String { "gui/\(getuid())" }
    private var target: String { "\(domain)/\(job.label)" }

    private static func runLaunchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: Self.label,
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "Could not update the schedule." : message]
            )
        }
    }

    private func isLoaded() throws -> Bool {
        do {
            try launchctl(["print", target])
            return true
        } catch let error as NSError where error.domain == Self.label && error.code == Self.serviceNotFound {
            return false
        }
    }

    private func installedAgentAppPath() -> String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              let appFlagIndex = args.firstIndex(of: "-a"),
              args.indices.contains(appFlagIndex + 1) else {
            return nil
        }
        return args[appFlagIndex + 1]
    }

    func status() -> LaunchAgentStatus {
        do {
            guard try isLoaded() else {
                do {
                    _ = try FileManager.default.attributesOfItem(atPath: plistURL.path)
                    return .pendingLoad
                } catch where ArchiveService.isMissingFolderError(error) {
                    return .disabled
                }
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
        let currentPath = Bundle.main.bundleURL.standardizedFileURL.path
        if let installed = installedAgentAppPath(),
           URL(fileURLWithPath: installed).standardizedFileURL.path != currentPath {
            return .stalePath(installedPath: installed)
        }
        return .enabled
    }

    func setAutomatic(_ enabled: Bool) throws {
        let bootout = Result { try launchctl(["bootout", target]) }
        // A job that was already absent can make bootout fail. Verify with launchd
        // before touching the plist, including when bootout reported success.
        if try isLoaded() {
            try bootout.get()
            throw NSError(domain: Self.label, code: Int(EBUSY), userInfo: [
                NSLocalizedDescriptionKey: "The scheduled job is still loaded. Try again."
            ])
        }

        guard enabled else {
            do {
                try FileManager.default.removeItem(at: plistURL)
            } catch where ArchiveService.isMissingFolderError(error) {
                // Already removed.
            }
            return
        }
        var plist: [String: Any] = [
            "Label": job.label,
            "ProgramArguments": [
                "/usr/bin/open", "-g", "-W", "-n", "-a",
                Bundle.main.bundleURL.path,
                "--args", job == .cleanup ? "--background" : "--backup"
            ],
            "ProcessType": "Background",
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "com.jmitch.screenshot-archive.helper"]
        ]
        switch job {
        case .cleanup:
            plist["RunAtLoad"] = true
            plist["StartInterval"] = 3600
        case .backup:
            plist["StartCalendarInterval"] = ["Hour": 20, "Minute": 0]
        }
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        do {
            try launchctl(["bootstrap", domain, plistURL.path])
        } catch {
            if (try? isLoaded()) == false {
                try? FileManager.default.removeItem(at: plistURL)
            }
            throw error
        }
    }
}
