import Foundation
import CryptoKit

/// A compiler-map transaction has one immutable operation identity per engine
/// generation. A lost socket reply never authorizes a second or overlapping map.
final class CompilationRegistrationRegistry {
    struct Outcome { let registeredCount: Int; let sources: [String] }
    typealias Apply = ([[String: Any]], () -> Bool) throws -> Outcome
    private struct Operation {
        let mapDigest: String
        let provenanceDigest: String
        let commandCount: Int
        let expiresAt: Double
        var state = "pending"
        var registeredCount = 0
        var sources: [String] = []
        var error = ""
    }
    let instanceNonce: String
    private let now: () -> Double
    private let enqueue: (@escaping () -> Void) -> Void
    private let mutex = NSLock()
    private var operations: [String: Operation] = [:]
    private var active: String?
    private var current: String?
    private var generation = 0

    init(instanceNonce: String, now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
         enqueue: @escaping (@escaping () -> Void) -> Void) {
        self.instanceNonce = instanceNonce; self.now = now; self.enqueue = enqueue
    }
    private func locked<T>(_ body: () -> T) -> T { mutex.lock(); defer { mutex.unlock() }; return body() }
    private func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    private func validDigest(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    private func binding(_ params: [String: Any]) -> (String, String, String)? {
        guard params["expected_engine_nonce"] as? String == instanceNonce,
              let id = params["registration_id"] as? String, UUID(uuidString: id) != nil,
              let map = params["map_digest"] as? String, validDigest(map),
              let provenance = params["provenance_digest"] as? String, validDigest(provenance) else { return nil }
        return (id, map, provenance)
    }
    private func receipt(_ id: String, _ operation: Operation) -> [String: Any] {
        var result: [String: Any] = ["compilation_registration_protocol": 1, "engine_instance_nonce": instanceNonce,
            "registration_id": id, "map_digest": operation.mapDigest, "provenance_digest": operation.provenanceDigest,
            "state": operation.state == "committed" && (current != id || (active != nil && active != id)) ? "superseded" : operation.state, "command_count": operation.commandCount,
            "current_registration_id": current ?? "", "activation_generation": generation,
            "registered_count": operation.registeredCount, "sources": operation.sources]
        if !operation.error.isEmpty { result["error_code"] = operation.error }
        return result
    }
    func query(_ params: [String: Any]) -> ControlServer.ActionResult {
        if params["registration_id"] == nil {
            return locked {
                var result: [String: Any] = ["compilation_registration_protocol": 1, "engine_instance_nonce": instanceNonce, "activation_generation": generation]
                if let id = active, let operation = operations[id] { result["pending_registration"] = receipt(id, operation) }
                if let id = current, let operation = operations[id] { result["current_registration"] = receipt(id, operation) }
                return .ok(result)
            }
        }
        guard let (id, map, provenance) = binding(params) else { return .fail("COMPILATION_REGISTRATION_BINDING_INVALID") }
        return locked {
            guard let operation = operations[id] else { return .ok(["compilation_registration_protocol": 1,
                "engine_instance_nonce": instanceNonce, "registration_id": id, "map_digest": map,
                "provenance_digest": provenance, "state": "unknown"]) }
            guard operation.mapDigest == map, operation.provenanceDigest == provenance else { return .fail("COMPILATION_REGISTRATION_CONFLICT") }
            return .ok(receipt(id, operation))
        }
    }
    func begin(_ params: [String: Any], apply: @escaping Apply) -> ControlServer.ActionResult {
        guard let (id, map, provenance) = binding(params),
              let text = params["payload_json"] as? String, text.utf8.count <= 4 * 1024 * 1024,
              let payload = text.data(using: .utf8), digest(payload) == map,
              let commands = try? JSONSerialization.jsonObject(with: payload) as? [[String: Any]],
              !commands.isEmpty, commands.count <= 1024,
              params["command_count"] as? Int == commands.count else { return .fail("COMPILATION_REGISTRATION_INVALID") }
        for command in commands {
            guard let args = command["arguments"] as? [String], args.count >= 3, args.count <= 32768,
                  args[0] == "-frontend", args[1] == "-c", args.allSatisfy({ $0.utf8.count <= 65536 }),
                  let directory = command["working_directory"] as? String, directory.hasPrefix("/"), directory.utf8.count <= 4096 else { return .fail("COMPILATION_REGISTRATION_COMMAND_INVALID") }
        }
        let result: ControlServer.ActionResult = locked {
            if let operation = operations[id] {
                guard operation.mapDigest == map, operation.provenanceDigest == provenance else { return .fail("COMPILATION_REGISTRATION_CONFLICT") }
                return .ok(receipt(id, operation)) // Already committed receipts survive expiry.
            }
            guard active == nil else { return .fail("COMPILATION_REGISTRATION_BUSY") }
            guard operations.count < 128 else { return .fail("COMPILATION_REGISTRATION_CAPACITY") }
            guard let expiry = params["expires_at_ms"] as? Double, expiry.isFinite,
                  expiry > now(), expiry <= now() + 180_000 else { return .fail("COMPILATION_REGISTRATION_EXPIRED") }
            let operation = Operation(mapDigest: map, provenanceDigest: provenance, commandCount: commands.count, expiresAt: expiry)
            operations[id] = operation; active = id; generation += 1
            return .ok(receipt(id, operation))
        }
        guard result.success, result.data?["state"] as? String == "pending" else { return result }
        // A duplicate pending request must not schedule the map again.
        let shouldSchedule = locked { () -> Bool in
            guard operations[id]?.state == "pending", active == id else { return false }
            operations[id]?.state = "scheduled"; return true
        }
        if shouldSchedule {
            enqueue { [weak self] in self?.perform(id, commands: commands, apply: apply) }
        }
        return query(params)
    }
    private func perform(_ id: String, commands: [[String: Any]], apply: Apply) {
        do {
            let outcome = try apply(commands) { [self] in
                locked {
                    guard var operation = operations[id], operation.state == "scheduled", active == id else { return false }
                    guard operation.expiresAt > now() else {
                        operation.state = "cancelled"; operation.error = "COMPILATION_REGISTRATION_EXPIRED"; operations[id] = operation; return false
                    }
                    operation.state = "committing"; operations[id] = operation; return true
                }
            }
            locked {
                guard var operation = operations[id] else { return }
                if operation.state == "committing", outcome.registeredCount > 0, !outcome.sources.isEmpty {
                    operation.state = "committed"; operation.registeredCount = outcome.registeredCount
                    current = id
                    operation.sources = Array(Set(outcome.sources)).sorted()
                } else if operation.state != "cancelled" {
                    operation.state = "failed"; operation.error = "COMPILATION_REGISTRATION_NOT_COMMITTED"
                }
                operations[id] = operation; active = nil
            }
        } catch {
            locked {
                guard var operation = operations[id] else { return }
                if operation.state != "cancelled" { operation.state = "failed"; operation.error = "COMPILATION_REGISTRATION_COMMIT_FAILED" }
                operations[id] = operation; active = nil
            }
        }
    }
}

import Darwin

/// The private control socket has absolute deadlines and never sends SIGPIPE
/// into the engine after a timed-out requesting process closes its socket.
enum CompilationControlTransport {
    struct FrameError: Error {}
    static let maximumFrameBytes = 8 * 1024 * 1024
    static let maximumResponseBytes = 32 * 1024 * 1024
    static func configure(_ socket: Int32) {
        var value: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout.size(ofValue: value)))
    }
    private static func timeout(_ socket: Int32, option: Int32, remaining: TimeInterval) {
        let seconds = max(0.001, remaining)
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        _ = setsockopt(socket, SOL_SOCKET, option, &value, socklen_t(MemoryLayout.size(ofValue: value)))
    }
    static func read(_ socket: Int32, timeoutSeconds: TimeInterval = 5) throws -> Data {
        configure(socket)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            timeout(socket, option: SO_RCVTIMEO, remaining: deadline.timeIntervalSinceNow)
            let count = recv(socket, &buffer, buffer.count, 0)
            guard count > 0 else { throw FrameError() }
            guard data.count + count <= maximumFrameBytes else { throw FrameError() }
            data.append(contentsOf: buffer[0..<count])
            if let end = data.firstIndex(of: UInt8(ascii: "\n")) { return data.prefix(upTo: end) }
        }
        throw FrameError()
    }
    @discardableResult
    static func write(_ data: Data, socket: Int32, timeoutSeconds: TimeInterval = 5) -> Bool {
        configure(socket)
        guard data.count <= maximumResponseBytes else { return false }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count && Date() < deadline {
                timeout(socket, option: SO_SNDTIMEO, remaining: deadline.timeIntervalSinceNow)
                let sent = send(socket, base.advanced(by: offset), bytes.count - offset, MSG_NOSIGNAL)
                guard sent > 0 else { return false }
                offset += sent
            }
            return offset == bytes.count
        }
    }
}

/// One owner-private atomic file is the durable commit point for every platform.
/// Existing unsafe files and links fail closed, including during engine restart.
enum CompilationRegistrationSnapshotStore {
    struct SnapshotError: Error {}
    static let maximumBytes = 64 * 1024 * 1024
    private static func check(_ path: String, directory: Bool) throws -> Bool {
        var info = stat()
        if lstat(path, &info) != 0 { if errno == ENOENT { return false }; throw SnapshotError() }
        guard info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), directory || info.st_nlink == 1 else { throw SnapshotError() }
        return true
    }
    static func read(_ url: URL) throws -> Data? {
        guard try check(url.path, directory: false) else { return nil }
        _ = try check(url.deletingLastPathComponent().path, directory: true)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw SnapshotError() }; defer { close(fd) }
        var output = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return output }
            guard count > 0, output.count + count <= maximumBytes else { throw SnapshotError() }
            output.append(contentsOf: buffer[0..<count])
        }
    }
    static func write(_ data: Data, to url: URL) throws {
        guard data.count <= maximumBytes else { throw SnapshotError() }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try check(parent.path, directory: true)
        _ = try check(parent.deletingLastPathComponent().path, directory: true)
        _ = try check(url.path, directory: false)
        let temporary = parent.appendingPathComponent(".compilation-map-\(UUID().uuidString).json").path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw SnapshotError() }
        defer { close(fd); unlink(temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let base = bytes.baseAddress else { throw SnapshotError() }
                let written = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { throw SnapshotError() }
                offset += written
            }
        }
        guard fsync(fd) == 0, rename(temporary, url.path) == 0 else { throw SnapshotError() }
        let directoryFD = open(parent.path, O_RDONLY)
        guard directoryFD >= 0 else { throw SnapshotError() }; defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw SnapshotError() }
    }
}
