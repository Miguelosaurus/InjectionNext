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
    func preparedMetadata() -> [String: Any]? { Self.metadata }
    static func preparedTarget() -> (InjectionServer, [String: Any])? {
        guard let metadata else { return nil }; return (client, metadata)
    }
    func writeCommand(_ command: Int, with json: String) -> Bool { Self.commands += 1; return true }
    func write(_ data: Data) -> Bool { Self.lastBytes = data; return true }
    func writePrepared(command: Int, metadata: String, data: Data, timeout: Double) -> Bool {
        Self.commands += 1; Self.lastBytes = data; return true
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
}
