import Foundation
import ImageIO
import Darwin

/// Small, demand-driven private artifacts. No periodic collector or cleanup worker.
final class DeveloperReportStore {
    static let shared = DeveloperReportStore(root: URL(fileURLWithPath:
        NSHomeDirectory() + "/.swift-sim/developer-reports", isDirectory: true))
    static let maxImageBytes = 1_048_576
    private let root: URL
    private let clock: () -> Date
    private let lock = NSLock()

    init(root: URL, clock: @escaping () -> Date = Date.init) {
        self.root = root
        self.clock = clock
    }

    enum Failure: String, Error {
        case invalid = "DEVELOPER_REPORT_INVALID"
        case unavailable = "DEVELOPER_REPORT_UNAVAILABLE"
        case conflict = "DEVELOPER_REPORT_CONFLICT"
        case missing = "REPORT_NOT_FOUND"
    }

    static func matches(_ identity: [String: Any], selector: [String: Any]) -> Bool {
        ["bundle_id", "executable_uuid", "debug_dylib_uuid"].allSatisfy { key in
            guard let expected = selector[key] as? String, !expected.isEmpty,
                  expected.utf8.count <= 256, let actual = identity[key] as? String else { return false }
            return key == "bundle_id" ? expected == actual : expected.lowercased() == actual.lowercased()
        }
    }

    static func sameCaptureIdentity(_ identity: [String: Any], _ expected: [String: Any]) -> Bool {
        guard matches(identity, selector: expected),
              let revision = identity["root_revision"] as? Int, revision >= 0,
              revision == expected["root_revision"] as? Int,
              identity["is_active"] as? Bool == true, expected["is_active"] as? Bool == true else { return false }
        return ["process_nonce", "connection_nonce"].allSatisfy { key in
            guard let value = identity[key] as? String else { return false }
            return value == expected[key] as? String
        }
    }

    static func validJPEG(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maxImageBytes,
              data.starts(with: [0xff, 0xd8, 0xff]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 2_000_000 / height else { return false }
        return true
    }

    private static func metadata(_ input: [String: Any]) throws -> [String: Any] {
        guard let reportID = input["report_id"] as? String, UUID(uuidString: reportID) != nil,
              input["schema_version"] as? Int == 1,
              let bytes = try? JSONSerialization.data(withJSONObject: input), bytes.count <= 16_384 else { throw Failure.invalid }
        var result: [String: Any] = ["schema_version": 1, "report_id": reportID.lowercased()]
        for (key, maximum) in [("app_name", 256), ("note", 2_048)] {
            if let value = input[key] {
                guard let value = value as? String, value.utf8.count <= maximum else { throw Failure.invalid }
                result[key] = value
            }
        }
        if let value = input["captured_at"] {
            if let date = value as? String, date.utf8.count <= 64 { result["captured_at"] = date }
            else if let date = value as? Double, date.isFinite, date >= 0 { result["captured_at"] = date }
            else { throw Failure.invalid }
        }
        if let phase = input["phase"] {
            guard let phase = phase as? String,
                  ["receiving", "applying", "waiting-for-refresh", "refreshed", "failed"].contains(phase) else { throw Failure.invalid }
            result["phase"] = phase
        }
        if let revision = input["revision"] {
            guard let value = revision as? Int, value >= 0 else { throw Failure.invalid }
            result["revision"] = value
        }
        if let requestID = input["request_id"] {
            guard let value = requestID as? String, UUID(uuidString: value) != nil else { throw Failure.invalid }
            result["request_id"] = value.lowercased()
        }
        return result
    }

    private static func identity(_ input: [String: Any]) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for key in ["bundle_id", "bundle_version", "build_number", "executable_uuid", "debug_dylib_uuid", "process_nonce", "connection_nonce"] {
            guard let value = input[key] as? String, value.utf8.count <= 256,
                  !value.isEmpty || key == "bundle_version" else { throw Failure.invalid }
            result[key] = value
        }
        guard let active = input["is_active"] as? Bool, let ready = input["root_ready"] as? Bool,
              let revision = input["root_revision"] as? Int, revision >= 0 else { throw Failure.invalid }
        result["is_active"] = active; result["root_ready"] = ready; result["root_revision"] = revision
        return result
    }

    @discardableResult
    func save(metadata raw: [String: Any], image: Data, identity rawIdentity: [String: Any]) throws -> [String: Any] {
        let metadata = try Self.metadata(raw)
        let identity = try Self.identity(rawIdentity)
        guard image.isEmpty || Self.validJPEG(image) else { throw Failure.invalid }
        lock.lock(); defer { lock.unlock() }
        try ensureRoot(create: true)
        try prune()
        let reportID = metadata["report_id"] as! String
        let path = root.appendingPathComponent(reportID + ".json")
        if FileManager.default.fileExists(atPath: path.path) {
            let existing = try read(path)
            guard let oldMetadata = existing["metadata"] as? [String: Any],
                  let oldIdentity = existing["identity"] as? [String: Any],
                  NSDictionary(dictionary: metadata).isEqual(to: oldMetadata),
                  NSDictionary(dictionary: identity).isEqual(to: oldIdentity),
                  (existing["screenshot"] as? [String: Any])?["data"] as? String == (image.isEmpty ? nil : image.base64EncodedString()) else { throw Failure.conflict }
            return existing
        }
        var result: [String: Any] = ["schema_version": 1, "report_id": reportID,
            "created_at": Self.dateFormatter().string(from: clock()), "identity": identity, "metadata": metadata]
        if !image.isEmpty { result["screenshot"] = ["mimeType": "image/jpeg", "bytes": image.count, "data": image.base64EncodedString()] }
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        guard encoded.count <= 1_500_000 else { throw Failure.invalid }
        try writePrivate(encoded, to: path)
        try prune()
        return result
    }

    private func writePrivate(_ data: Data, to destination: URL) throws {
        let temporary = root.appendingPathComponent(".pending-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        // Atomic publication without replacing an existing report or following a symlink.
        guard link(temporary.path, destination.path) == 0 else { throw Failure.conflict }
    }

    func latest(selector: [String: Any], reportID: String? = nil) throws -> [String: Any] {
        if let reportID, UUID(uuidString: reportID) == nil { throw Failure.invalid }
        guard ["bundle_id", "executable_uuid", "debug_dylib_uuid"].allSatisfy({ selector[$0] is String }) else { throw Failure.invalid }
        lock.lock(); defer { lock.unlock() }
        try ensureRoot(create: false)
        try prune()
        let reports = try files().filter {
            reportID == nil || $0.deletingPathExtension().lastPathComponent == reportID?.lowercased()
        }.compactMap { try? read($0) }.filter {
            guard let identity = $0["identity"] as? [String: Any] else { return false }
            return Self.matches(identity, selector: selector)
        }.sorted { ($0["created_at"] as? String ?? "") > ($1["created_at"] as? String ?? "") }
        if let report = reports.first { return report }
        throw Failure.missing
    }

    private static func dateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private func ensureRoot(create: Bool) throws {
        let manager = FileManager.default
        // Refuse symlinked parents, broad existing directories or foreign ownership.
        for directory in [root.deletingLastPathComponent(), root] {
            if !manager.fileExists(atPath: directory.path) {
                guard create else { throw Failure.missing }
                try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            }
            let attrs = try manager.attributesOfItem(atPath: directory.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw Failure.unavailable }
        }
    }

    private func files() throws -> [URL] {
        let paths = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard paths.count <= 100 else { throw Failure.unavailable }
        return paths.filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
    }

    private func read(_ path: URL) throws -> [String: Any] {
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(), status.st_nlink == 1, status.st_mode & 0o077 == 0,
              status.st_size > 0, status.st_size <= 1_500_000,
              let data = try handle.read(upToCount: 1_500_001), data.count == Int(status.st_size),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["schema_version"] as? Int == 1,
              result["report_id"] as? String == path.deletingPathExtension().lastPathComponent,
              let date = result["created_at"] as? String,
              let created = Self.dateFormatter().date(from: date), created <= clock(),
              let metadata = result["metadata"] as? [String: Any],
              let identity = result["identity"] as? [String: Any] else { throw Failure.unavailable }
        _ = try Self.metadata(metadata); _ = try Self.identity(identity)
        if let screenshot = result["screenshot"] as? [String: Any] {
            guard screenshot["mimeType"] as? String == "image/jpeg",
                  let base64 = screenshot["data"] as? String,
                  let image = Data(base64Encoded: base64), Self.validJPEG(image),
                  screenshot["bytes"] as? Int == image.count else { throw Failure.unavailable }
        }
        return result
    }

    private func prune() throws {
        var valid: [(URL, Date, Int)] = []
        for path in try files() {
            let value = try read(path)
            guard let text = value["created_at"] as? String,
                  let date = Self.dateFormatter().date(from: text) else { throw Failure.unavailable }
            if clock().timeIntervalSince(date) >= 86_400 { try FileManager.default.removeItem(at: path) }
            else { valid.append((path, date, (try JSONSerialization.data(withJSONObject: value)).count)) }
        }
        valid.sort { $0.1 < $1.1 }
        while valid.count > 5 || valid.reduce(0, { $0 + $1.2 }) > 10 * 1_024 * 1_024 {
            try FileManager.default.removeItem(at: valid.removeFirst().0)
        }
    }
}
