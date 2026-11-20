import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct BackupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct BackupDestination: Codable, Equatable, Sendable {
    var endpoint = ""
    var region = "us-east-1"
    var bucket = ""
    var prefix = "screenshots"
    var accessKeyID = ""

    func validated() throws -> Self {
        var result = self
        result.region = region.trimmingCharacters(in: .whitespacesAndNewlines)
        result.bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        result.accessKeyID = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        result.prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard result.region.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil else {
            throw BackupError("Enter a signing region such as us-east-1 or auto.")
        }
        guard result.bucket.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw BackupError("Enter the bucket name, with the folder path in the prefix field.")
        }
        guard !result.accessKeyID.isEmpty,
              result.accessKeyID.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw BackupError("Enter the access key ID for this bucket.")
        }
        guard !result.prefix.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !result.prefix.contains("//"), result.prefix.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw BackupError("Enter a prefix made up of folder names separated by single slashes.")
        }
        let entered = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = entered.isEmpty ? "https://s3.\(result.region).amazonaws.com" : entered
        guard var parts = URLComponents(string: origin), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["", "/"].contains(parts.path),
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)) else {
            throw BackupError("Use an HTTPS S3 endpoint with the bucket name in its own field. Localhost also accepts HTTP.")
        }
        parts.host = host
        parts.path = ""
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) {
            parts.port = nil
        }
        guard let url = parts.url else { throw BackupError("Invalid S3 endpoint.") }
        result.endpoint = url.absoluteString
        return result
    }
}

enum BackupKeychain {
    private static func query(for destination: BackupDestination) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.jmitch.screenshot-archive.backup.\(destination.endpoint)",
         kSecAttrAccount as String: destination.accessKeyID]
    }

    static func read(for destination: BackupDestination, interactive: Bool) throws -> String {
        var query = query(for: destination)
        query[kSecReturnData as String] = true
        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw BackupError("Enter a secret access key for this endpoint and access key ID.") }
        try check(status)
        guard let data = item as? Data, let secret = String(data: data, encoding: .utf8), !secret.isEmpty else {
            throw BackupError("The saved secret is unreadable. Enter it again in Backup Settings.")
        }
        return secret
    }

    static func save(_ secret: String, for destination: BackupDestination) throws {
        let query = query(for: destination)
        let value = [kSecValueData as String: Data(secret.utf8)]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(secret.utf8)
            item[kSecAttrLabel as String] = "Screenshot Archive S3 backup"
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        throw BackupError("Keychain: \(reason)")
    }
}

private extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

struct S3Upload {
    let destination: BackupDestination
    let secret: String

    func request(filename: String, payloadHash: String, date: Date) throws -> URLRequest {
        let destination = try destination.validated()
        let key = [destination.bucket, destination.prefix, filename].filter { !$0.isEmpty }.joined(separator: "/")
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        guard var parts = URLComponents(string: destination.endpoint),
              let path = ("/" + key).addingPercentEncoding(withAllowedCharacters: unreserved),
              let host = parts.host else { throw BackupError("Invalid backup object URL.") }
        parts.percentEncodedPath = path
        guard let url = parts.url else { throw BackupError("Invalid backup object URL.") }
        let authority = host + (parts.port.map { ":\($0)" } ?? "")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date)
        let day = String(timestamp.prefix(8))
        let scope = "\(day)/\(destination.region)/s3/aws4_request"
        let headers = "content-type:application/zip\nhost:\(authority)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(timestamp)\n"
        let signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date"
        let canonical = ["PUT", path, "", headers, signedHeaders, payloadHash].joined(separator: "\n")
        let stringToSign = ["AWS4-HMAC-SHA256", timestamp, scope, SHA256.hash(data: Data(canonical.utf8)).hex].joined(separator: "\n")
        var keyBytes = Data(("AWS4" + secret).utf8)
        for part in [day, destination.region, "s3", "aws4_request"] {
            keyBytes = Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: SymmetricKey(data: keyBytes)))
        }
        let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: SymmetricKey(data: keyBytes)).hex
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        request.setValue("AWS4-HMAC-SHA256 Credential=\(destination.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }

    func upload(_ file: URL) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size <= 5 * 1024 * 1024 * 1024 else { throw BackupError("This ZIP exceeds the 5 GiB single-upload limit.") }
        try handle.seek(toOffset: 0)
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        let request = try request(filename: file.lastPathComponent, payloadHash: hash.finalize().hex, date: Date())
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: BackupRedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse else { throw BackupError("No HTTP response from object storage.") }
        guard (200..<300).contains(http.statusCode) else {
            throw BackupError("Upload failed (HTTP \(http.statusCode)). Check the endpoint, region, bucket, and write credentials.")
        }
        guard http.value(forHTTPHeaderField: "ETag")?.isEmpty == false else {
            throw BackupError("Object storage did not confirm the uploaded ZIP. Check the S3 API endpoint.")
        }
    }
}

private final class BackupRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct ObjectBackup: Sendable {
    let folder: URL
    let screenshotPrefixes: [String]

    init(folder: URL, screenshotPrefixes: [String] = [ArchiveService.defaultPrefix]) {
        self.folder = folder
        self.screenshotPrefixes = screenshotPrefixes.isEmpty ? [ArchiveService.defaultPrefix] : screenshotPrefixes
    }

    func run(upload: (URL) async throws -> Void) async throws -> String {
        let paths = try screenshotPaths()
        guard !paths.isEmpty else { return "No screenshots to back up." }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("screenshot-backup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }

        let list = temp.appendingPathComponent("files")
        var manifest = Data()
        for path in paths {
            manifest.append(contentsOf: path.utf8)
            manifest.append(0)
        }
        try manifest.write(to: list)
        let timestamp = Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        let zip = temp.appendingPathComponent("Screenshots-\(timestamp)-\(UUID().uuidString).zip")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", zip.path, "--format", "zip", "--no-mac-metadata", "--no-recursion",
                         "-C", folder.path, "--null", "-T", list.path]
        let pipe = Pipe()
        tar.standardError = pipe
        try tar.run()
        let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            let reason = String(decoding: errorData.suffix(1500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BackupError("Could not create backup ZIP. \(reason)")
        }
        try await upload(zip)
        return "Backed up \(paths.count) screenshot\(paths.count == 1 ? "" : "s")."
    }

    private func screenshotPaths() throws -> [String] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var paths: [String] = []
        func collect(in directory: URL, prefix: String) throws {
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
            for entry in entries {
                let name = entry.lastPathComponent
                let isArchive = prefix.isEmpty && name == "Archive"
                let isMonth = prefix == "Archive/" && name.range(of: #"^[0-9]{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil
                guard isArchive || isMonth || ArchiveService.isScreenshot(name, prefixes: screenshotPrefixes) else { continue }
                let info = try entry.resourceValues(forKeys: keys)
                if isArchive && info.isSymbolicLink == true { throw ArchiveError.archiveIsSymlink }
                guard info.isSymbolicLink != true else { continue }
                if isArchive || isMonth {
                    if info.isDirectory == true { try collect(in: entry, prefix: prefix + name + "/") }
                    else if isArchive { throw ArchiveError.archiveIsNotDirectory }
                } else if info.isRegularFile == true {
                    paths.append(prefix + name)
                }
            }
        }
        try collect(in: folder, prefix: "")
        return paths
    }
}
