import Foundation
import CryptoKit
import Darwin

class ControlServer {
    struct ActionResult {
        let success: Bool; let data: [String: Any]?; let error: String?
        static func ok(_ data: [String: Any]? = nil) -> ActionResult { ActionResult(success: true, data: data, error: nil) }
        static func fail(_ error: String) -> ActionResult { ActionResult(success: false, data: nil, error: error) }
    }
}
@main
struct RegistrationTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
    static func main() throws {
        var time: Double = 1000; var jobs: [() -> Void] = []; var effects = 0
        let registry = CompilationRegistrationRegistry(instanceNonce: "engine-one", now: { time }, enqueue: { jobs.append($0) })
        let commands = (0..<150).map { index in ["arguments": ["-frontend", "-c", "-module-name", "Dependency", "/tmp/Source\(index).swift"], "working_directory": "/tmp"] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: commands)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var request: [String: Any] = ["registration_id": UUID().uuidString, "map_digest": digest,
            "provenance_digest": String(repeating: "a", count: 64), "expected_engine_nonce": "engine-one",
            "payload_json": String(data: data, encoding: .utf8)!, "expires_at_ms": 2000.0, "command_count": commands.count]
        let apply: CompilationRegistrationRegistry.Apply = { commands, permit in
            require(commands.count == 150, "all commands retained")
            require(permit(), "valid commit admitted")
            effects += 1
            return .init(registeredCount: 150, sources: (0..<150).map { "/tmp/Source\($0).swift" })
        }
        require(registry.begin(request, apply: apply).success, "map admitted")
        require(registry.begin(request, apply: apply).success && jobs.count == 1, "pending retry schedules no duplicate")
        require(registry.query(request).data?["state"] as? String == "scheduled", "lost response remains queryable")
        var another = request; another["registration_id"] = UUID().uuidString
        require(registry.begin(another, apply: apply).error == "COMPILATION_REGISTRATION_BUSY", "new map cannot overlap old late operation")
        jobs.removeFirst()()
        require(effects == 1 && registry.query(request).data?["state"] as? String == "committed", "all commands committed exactly once")
        time = 10000
        require(registry.begin(request, apply: apply).data?["state"] as? String == "committed" && jobs.isEmpty, "committed receipt survives expiry")
        let originalRequest = request
        var conflict = request; conflict["provenance_digest"] = String(repeating: "b", count: 64)
        require(registry.begin(conflict, apply: apply).error == "COMPILATION_REGISTRATION_CONFLICT", "same ID wrong capture denied")
        conflict = request; conflict["expected_engine_nonce"] = "engine-two"
        require(!registry.query(conflict).success, "receipt cannot cross engine generations")
        request["registration_id"] = UUID().uuidString; request["expires_at_ms"] = 11000.0
        require(registry.begin(request) { _, permit in
            require(!permit(), "expired staged work cannot commit")
            return .init(registeredCount: 0, sources: [])
        }.success, "second map staged")
        time = 12000; jobs.removeFirst()()
        require(registry.query(request).data?["state"] as? String == "cancelled", "expired partial parse is terminal without effect")
        require(effects == 1, "no expired or duplicate operation changes compiler state")
        request["registration_id"] = UUID().uuidString; request["expires_at_ms"] = 13000.0; request["provenance_digest"] = String(repeating: "b", count: 64)
        require(registry.begin(request, apply: apply).success, "different map activation admitted after old terminal")
        jobs.removeFirst()()
        require(registry.query(originalRequest).data?["state"] as? String == "superseded", "historical receipt cannot qualify the current map")
        require(registry.begin(originalRequest, apply: apply).data?["state"] as? String == "superseded" && jobs.isEmpty, "historical id never reexecutes itself")
        var reactivate = originalRequest; reactivate["registration_id"] = UUID().uuidString; reactivate["expires_at_ms"] = 13000.0
        require(registry.begin(reactivate, apply: apply).success, "explicit new metadata activation can restore an older capture")
        jobs.removeFirst()()
        require(effects == 3 && registry.query(reactivate).data?["state"] as? String == "committed", "A to B to A requires a current activation receipt")
        struct FixtureFailure: Error {}
        var failedAttempt = originalRequest; failedAttempt["registration_id"] = UUID().uuidString; failedAttempt["expires_at_ms"] = 13000.0
        let beforeFailureGeneration = registry.query([:]).data?["activation_generation"] as! Int
        require(registry.begin(failedAttempt) { _, _ in throw FixtureFailure() }.success, "failing metadata attempt admitted")
        jobs.removeFirst()()
        require(registry.query(failedAttempt).data?["state"] as? String == "failed", "failure remains a terminal receipt")
        require((registry.query([:]).data?["activation_generation"] as! Int) > beforeFailureGeneration, "failed attempt advances next activation identity")
        let retryGeneration = registry.query([:]).data?["activation_generation"] as! Int
        var freshAttempt = failedAttempt; freshAttempt["registration_id"] = UUID().uuidString
        require(registry.begin(freshAttempt, apply: apply).success, "same capture may retry with a new metadata attempt")
        jobs.removeFirst()()
        require(effects == 4 && (registry.query([:]).data?["activation_generation"] as! Int) > retryGeneration, "retry commits once without engine restart")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swift-sim-registration-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = directory.appendingPathComponent("private/map.json")
        let first = try JSONSerialization.data(withJSONObject: ["iPhoneOS": ["a": "old"], "MacOSX": ["host": "old"]])
        try CompilationRegistrationSnapshotStore.write(first, to: snapshot)
        let second = try JSONSerialization.data(withJSONObject: ["iPhoneOS": ["a": "new"], "MacOSX": ["host": "new"]])
        try CompilationRegistrationSnapshotStore.write(second, to: snapshot)
        let loaded = try CompilationRegistrationSnapshotStore.read(snapshot)
        require(loaded == second, "one atomic snapshot covers both platforms")
        let attributes = try FileManager.default.attributesOfItem(atPath: snapshot.path)
        require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "snapshot owner private")
        try FileManager.default.removeItem(at: snapshot)
        try FileManager.default.createSymbolicLink(at: snapshot, withDestinationURL: directory.appendingPathComponent("elsewhere"))
        require((try? CompilationRegistrationSnapshotStore.write(first, to: snapshot)) == nil, "unsafe existing link rejected")
        var pair = [Int32](repeating: -1, count: 2)
        require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0, "socket pair")
        close(pair[1])
        require(!CompilationControlTransport.write(Data("late response\n".utf8), socket: pair[0], timeoutSeconds: 0.05), "late closed reader does not SIGPIPE engine")
        close(pair[0])
        require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0, "backpressure socket pair")
        var small: Int32 = 4096
        _ = setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &small, socklen_t(MemoryLayout.size(ofValue: small)))
        let started = Date()
        require(!CompilationControlTransport.write(Data(repeating: 42, count: 1024 * 1024), socket: pair[0], timeoutSeconds: 0.05), "blocked reader bounded")
        require(Date().timeIntervalSince(started) < 0.5, "absolute write deadline")
        close(pair[0]); close(pair[1])
        require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0, "read socket pair")
        let readStarted = Date()
        require((try? CompilationControlTransport.read(pair[0], timeoutSeconds: 0.05)) == nil, "stalled frame bounded")
        require(Date().timeIntervalSince(readStarted) < 0.5, "absolute read deadline")
        close(pair[0]); close(pair[1])
        print("Transactional compiler registration and late socket behavior checks passed")
    }
}
