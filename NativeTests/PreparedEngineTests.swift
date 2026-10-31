import Cocoa
import CryptoKit

final class ConfigStore {
    static let shared = ConfigStore()
    var codesigningIdentity: String? = "-"
}
class ControlServer {
    struct ActionResult {
        let success: Bool
        let data: [String: Any]?
        let error: String?
        static func ok(_ data: [String: Any]? = nil) -> ActionResult { ActionResult(success: true, data: data, error: nil) }
        static func fail(_ error: String) -> ActionResult { ActionResult(success: false, data: nil, error: error) }
    }
}
enum InjectionCommand: Int { case preparedInject = 11 }
final class InjectionServer {
    static let clientQueue = DispatchQueue(label: "FixtureWriter")
    static let client = InjectionServer()
    static var metadata: [String: Any]?
    static var commands = 0
    static var lastBytes = Data()
    static var lastMetadata = ""
    func preparedMetadata() -> [String: Any]? { Self.metadata }
    static func preparedTarget() -> (InjectionServer, [String: Any])? {
        guard let metadata else { return nil }; return (client, metadata)
    }
    func writeCommand(_ command: Int, with json: String) -> Bool { Self.commands += 1; return true }
    func write(_ data: Data) -> Bool { Self.lastBytes = data; return true }
    func writePrepared(command: Int, metadata: String, data: Data, timeout: Double) -> Bool {
        Self.commands += 1; Self.lastBytes = data; Self.lastMetadata = metadata; return true
    }
}

@main
struct PreparedEngineTests {
    static func require(_ value: Bool, _ message: String) {
        if !value { fatalError(message) }
    }
    static func main() throws {
        let root = CommandLine.arguments[1]
        let path = root + "/fixture.dylib"
        let prepared = PreparedDeliveryEngine.prepare(["path": path, "platform": "iPhoneSimulator"])
        require(prepared.success, "signed fixture prepares")
        let digest = prepared.data!["patch_digest"] as! String
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        require(digest == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), "digest covers final signed bytes")
        let again = PreparedDeliveryEngine.prepare(["path": path, "platform": "iPhoneSimulator"])
        require(again.data?["patch_digest"] as? String == digest, "preparation is idempotent for signed bytes")
        let identity: [String: Any] = ["bundle_id": "example.fixture", "build_number": "7", "executable_uuid": "fixture-executable",
            "debug_dylib_uuid": "fixture-debug", "process_nonce": "fixture-process", "root_revision": 0, "is_active": true, "root_ready": true]
        InjectionServer.metadata = ["identity": identity, "capabilities": PreparedDeliveryEngine.capabilities]
        let id = UUID().uuidString
        var request: [String: Any] = ["request_id": id, "patch_digest": digest, "path": path,
            "expires_at_ms": Date().timeIntervalSince1970 * 1_000 + 300_000, "baseline_revision": 0, "attempt_id": "attempt-a", "expected_identity": identity]
        require(PreparedDeliveryEngine.inject(request).success, "matched prepared request admitted")
        InjectionServer.clientQueue.sync {}
        require(InjectionServer.commands == 1 && InjectionServer.lastBytes == bytes, "exact signed bytes transmitted once")
        let pending = PreparedDeliveryEngine.query(["request_id": id, "patch_digest": digest])
        require(pending.data?["state"] as? String == "pending", "accepted is not completed")
        PreparedDeliveryEngine.record(["request_id": id, "patch_digest": digest, "client_identity": identity,
            "applied": true, "refresh_acknowledged": true, "root_revision": 1], from: InjectionServer.client)
        require(PreparedDeliveryEngine.query(["request_id": id, "patch_digest": digest]).data?["state"] as? String == "completed", "matching receipt available")
        require(PreparedDeliveryEngine.inject(request).data?["state"] as? String == "completed", "completed duplicate returns receipt")
        InjectionServer.clientQueue.sync {}
        require(InjectionServer.commands == 1, "completed duplicate does not resend")
        var wrongIdentity = identity; wrongIdentity["process_nonce"] = "different-process"
        request["expected_identity"] = wrongIdentity
        require(PreparedDeliveryEngine.inject(request).error == "PREPARED_IDENTITY_MISMATCH", "wrong process rejected")
        InjectionServer.metadata = ["identity": wrongIdentity, "capabilities": PreparedDeliveryEngine.capabilities]
        require(PreparedDeliveryEngine.query(["request_id": id, "patch_digest": digest]).data?["state"] as? String == "unknown", "no receipt borrowed across process generations")
        var inactive = identity; inactive["is_active"] = false
        InjectionServer.metadata = ["identity": inactive, "capabilities": PreparedDeliveryEngine.capabilities]
        request["expected_identity"] = identity
        require(PreparedDeliveryEngine.inject(request).error == "PREPARED_WAITING_FOR_FOREGROUND", "foreground required")
        InjectionServer.metadata = ["identity": identity, "capabilities": []]
        require(PreparedDeliveryEngine.inject(request).error == "PREPARED_CLIENT_UNAVAILABLE", "old client never receives prepared command")
        InjectionServer.metadata = ["identity": identity, "capabilities": PreparedDeliveryEngine.capabilities]
        request["request_id"] = UUID().uuidString
        request["expected_identity"] = identity
        request["attempt_id"] = "attempt-a"
        let retryID = request["request_id"] as! String
        require(PreparedDeliveryEngine.inject(request).success, "first race attempt admitted")
        let noEffect: [String: Any] = ["request_id": retryID, "patch_digest": digest, "client_identity": identity,
            "applied": false, "refresh_acknowledged": false, "admission": "rejected-no-effect",
            "error_code": "PREPARED_WAITING_FOR_FOREGROUND", "attempt_id": "attempt-a"]
        PreparedDeliveryEngine.record(noEffect, from: InjectionServer.client)
        require(PreparedDeliveryEngine.query(["request_id": retryID, "patch_digest": digest]).data?["state"] as? String == "rejected-no-effect", "pre-admission race is explicitly retryable")
        request["attempt_id"] = "attempt-b"
        require(PreparedDeliveryEngine.inject(request).success, "same operation retries on foreground")
        PreparedDeliveryEngine.record(noEffect, from: InjectionServer.client)
        require(PreparedDeliveryEngine.query(["request_id": retryID, "patch_digest": digest]).data?["state"] as? String == "pending", "stale attempt cannot reopen new apply")
        try testV3(path: path, digest: digest, identity: identity)
        require(!PreparedDeliveryEngine.prepare(["path": root + "/../outside.dylib"]).success, "artifact cannot escape owned root")
        try FileManager.default.createSymbolicLink(atPath: root + "/link.dylib", withDestinationPath: path)
        require(!PreparedDeliveryEngine.prepare(["path": root + "/link.dylib"]).success, "artifact symlink rejected")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        require(!PreparedDeliveryEngine.prepare(["path": path]).success, "world readable artifact rejected")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        ConfigStore.shared.codesigningIdentity = "fixture-missing-identity"
        require(!PreparedDeliveryEngine.prepare(["path": path, "platform": "iPhoneOS"]).success, "failed signing never returns prepared bytes")
        print("Prepared engine behavior checks passed")
    }
    static func testV3(path: String, digest: String, identity: [String: Any]) throws {
        let contract: [String: Any] = ["version": 3, "swift_replacements": 1, "objc_callbacks": []]
        let proof = try PreparedReplacementProof.parse(contract)!
        let capabilities = PreparedDeliveryEngine.capabilities + ["replacement-proof-v3"]
        func fresh() -> [String: Any] {
            ["request_id": UUID().uuidString, "patch_digest": digest, "path": path,
             "expires_at_ms": Date().timeIntervalSince1970 * 1_000 + 300_000, "baseline_revision": 0,
             "attempt_id": "initial", "expected_identity": identity, "replacement_proof": contract]
        }
        func query(_ request: [String: Any]) -> [String: Any] { PreparedDeliveryEngine.query(request).data! }
        func success(_ request: [String: Any]) -> [String: Any] {
            ["request_id": request["request_id"]!, "patch_digest": digest, "attempt_id": request["attempt_id"]!,
             "client_identity": identity, "replacement_proof_version": 3, "coverage_digest": proof.digest,
             "expected_swift_replacements": 1, "dynamic_replacements": 1, "objc_replacements": 0,
             "represented_replacements": 1, "objc_callback_proofs": [], "complete_replacement_coverage": true,
             "succeeded": true, "applied": true, "refresh_acknowledged": true, "root_revision": 1]
        }
        func noEffect(_ request: [String: Any]) -> [String: Any] {
            ["request_id": request["request_id"]!, "patch_digest": digest, "attempt_id": request["attempt_id"]!,
             "client_identity": identity, "replacement_proof_version": 3, "coverage_digest": proof.digest,
             "succeeded": false, "applied": false, "refresh_acknowledged": false,
             "admission": "rejected-no-effect", "error_code": "PREPARED_BASELINE_MISMATCH"]
        }
        let unsupported = fresh()
        require(PreparedDeliveryEngine.inject(unsupported).error == "PREPARED_REPLACEMENT_PROOF_UNSUPPORTED", "v3 requires advertised native capability")
        InjectionServer.metadata = ["identity": identity, "capabilities": capabilities]
        var invalid = fresh(); invalid["baseline_revision"] = true
        require(!PreparedDeliveryEngine.inject(invalid).success, "boolean baseline rejected")
        invalid = fresh(); var hugeIdentity = identity; hugeIdentity["extra"] = String(repeating: "x", count: 17_000); invalid["expected_identity"] = hugeIdentity
        require(PreparedDeliveryEngine.inject(invalid).error == "PREPARED_REQUEST_INVALID", "whole wire envelope bounded before send")
        let request = fresh()
        require(PreparedDeliveryEngine.inject(request).success, "v3 admits")
        InjectionServer.clientQueue.sync {}
        let sends = InjectionServer.commands
        let envelope = try JSONSerialization.jsonObject(with: Data(InjectionServer.lastMetadata.utf8)) as! [String: Any]
        require(try PreparedReplacementProof.parse(envelope["replacement_proof"])!.digest == proof.digest, "canonical coverage relayed")
        require(PreparedDeliveryEngine.inject(request).success, "pending duplicate attaches")
        InjectionServer.clientQueue.sync {}
        require(InjectionServer.commands == sends, "pending same attempt never sends twice")
        for key in ["replacement_proof", "attempt_id", "baseline_revision"] {
            var changed = request
            if key == "replacement_proof" { changed[key] = ["version": 3, "swift_replacements": 2, "objc_callbacks": []] }
            if key == "attempt_id" { changed[key] = "other" }
            if key == "baseline_revision" { changed[key] = 1 }
            require(!PreparedDeliveryEngine.inject(changed).success, "pending identity conflict: " + key)
        }
        for (key, value) in [("coverage_digest", "wrong" as Any), ("attempt_id", "stale"), ("root_revision", 0), ("root_revision", true), ("dynamic_replacements", true), ("succeeded", false), ("succeeded", 1), ("state_uncertain", true), ("complete_replacement_coverage", false), ("objc_callback_proofs", [["verified": true]])] {
            var tampered = success(request); tampered[key] = value
            PreparedDeliveryEngine.record(tampered, from: InjectionServer.client)
            require(query(request)["state"] as? String == "pending", "tampered report rejected: " + key)
        }
        for key in ["bundle_id", "build_number", "executable_uuid", "debug_dylib_uuid", "process_nonce"] {
            var changed = identity; changed[key] = "wrong"
            var tampered = success(request); tampered["client_identity"] = changed
            PreparedDeliveryEngine.record(tampered, from: InjectionServer.client)
            require(query(request)["state"] as? String == "pending", "report identity bound: " + key)
        }
        PreparedDeliveryEngine.record(success(request), from: InjectionServer.client)
        require(query(request)["state"] as? String == "completed", "exact v3 proof completes")
        var changed = request; changed["replacement_proof"] = ["version": 3, "swift_replacements": 2, "objc_callbacks": []]
        require(!PreparedDeliveryEngine.inject(changed).success, "cached success cannot hide changed expectations")
        require(PreparedDeliveryEngine.inject(request).data?["state"] as? String == "completed", "exact cached v3 returns proof")

        let retry = fresh(); require(PreparedDeliveryEngine.inject(retry).success, "retry fixture admitted")
        var uncertain = noEffect(retry); uncertain["state_uncertain"] = true
        PreparedDeliveryEngine.record(uncertain, from: InjectionServer.client)
        require(query(retry)["state"] as? String == "pending", "uncertainty cannot reopen apply")
        PreparedDeliveryEngine.record(noEffect(retry), from: InjectionServer.client)
        require(query(retry)["state"] as? String == "rejected-no-effect", "explicit pre-admission proof opens retry")
        InjectionServer.clientQueue.sync {}
        let beforeRetry = InjectionServer.commands
        let lock = NSLock(); var admitted = 0
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            var next = retry; next["attempt_id"] = "retry-\(index)"
            if PreparedDeliveryEngine.inject(next).success { lock.lock(); admitted += 1; lock.unlock() }
        }
        InjectionServer.clientQueue.sync {}
        require(admitted == 1 && InjectionServer.commands == beforeRetry + 1, "atomic retry claim allows exactly one concurrent fresh attempt and write")
        PreparedDeliveryEngine.record(noEffect(retry), from: InjectionServer.client)
        require(query(retry)["state"] as? String == "pending", "stale retry result cannot resolve new owner")
        print("Prepared v3 engine checks passed (including 32-way retry race)")
    }

}
