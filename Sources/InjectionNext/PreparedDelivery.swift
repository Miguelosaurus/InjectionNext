#if DEBUG || !SWIFT_PACKAGE
import Foundation
import CryptoKit

/// Count loaded Swift replacement definitions. A compiler emits a `TX`
/// replacement variable and may also emit a `TI` implementation variable. The
/// linker can dead-strip the unused TI while retaining the active replacement.
enum PreparedPatchEvidence {
    static let clientCapabilities = ["prepared-delivery-v1", "reconnect-v1", "receipt-v1", "replacement-proof-v2"]

    static func dynamicReplacementCount(in image: ImageSymbols) -> Int {
        Set(image.swiftSymbols(withSuffixes: ["TI", "TX"])
            .map { String($0.symbol.dropLast(2)) }).count
    }
}

/// A process-lifetime receipt ledger. It never evicts an accepted request and
/// therefore cannot turn an ambiguous transport retry into a second apply.
/// Capacity exhaustion fails closed until the next normal app process launch.
final class PreparedDeliveryLedger {
    static let shared = PreparedDeliveryLedger()
    struct Entry {
        let digest: String
        var report: [String: Any]?
        var callbacks: [([String: Any]) -> Void]
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let capacity: Int
    init(capacity: Int = 1_024) { self.capacity = capacity }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns true only for the single owner allowed to load this request.
    func begin(request: [String: Any], data: Data, identity: [String: Any],
               now: Double = Date().timeIntervalSince1970 * 1_000,
               deliver: @escaping ([String: Any]) -> Void) -> Bool {
        let requestID = request["request_id"] as? String ?? ""
        let digest = request["patch_digest"] as? String ?? ""
        func reject(_ code: String, noEffect: Bool = false) -> Bool {
            deliver(Self.failure(code, request: request, identity: identity, noEffect: noEffect))
            return false
        }
        guard UUID(uuidString: requestID) != nil,
              digest.count == 64, digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let expiry = request["expires_at_ms"] as? Double, expiry.isFinite,
              expiry > now, expiry <= now + 86_400_000,
              let baseline = request["baseline_revision"] as? Int, baseline >= 0,
              let attemptID = request["attempt_id"] as? String, !attemptID.isEmpty,
              attemptID.utf8.count <= 128 else {
            return reject("PREPARED_REQUEST_INVALID_OR_EXPIRED")
        }
        guard let expected = request["expected_identity"] as? [String: Any] else {
            return reject("PREPARED_IDENTITY_MISMATCH")
        }
        for key in ["bundle_id", "build_number", "executable_uuid", "debug_dylib_uuid", "process_nonce"] {
            guard let value = expected[key] as? String, !value.isEmpty,
                  value == identity[key] as? String else { return reject("PREPARED_IDENTITY_MISMATCH") }
        }
        guard Self.digest(data) == digest else { return reject("PREPARED_DIGEST_MISMATCH") }
        lock.lock()
        if var entry = entries[requestID] {
            guard entry.digest == digest else { lock.unlock(); return reject("PREPARED_REQUEST_CONFLICT") }
            if let report = entry.report { lock.unlock(); deliver(report); return false }
            guard entry.callbacks.count < 16 else { lock.unlock(); return reject("PREPARED_RECEIPT_BUSY") }
            entry.callbacks.append(deliver)
            entries[requestID] = entry
            lock.unlock()
            return false
        }
        guard identity["is_active"] as? Bool == true,
              identity["root_ready"] as? Bool == true else { lock.unlock(); return reject("PREPARED_WAITING_FOR_FOREGROUND", noEffect: true) }
        guard identity["root_revision"] as? Int == baseline else { lock.unlock(); return reject("PREPARED_BASELINE_MISMATCH", noEffect: true) }
        guard entries.count < capacity else { lock.unlock(); return reject("PREPARED_RECEIPT_CAPACITY") }
        entries[requestID] = Entry(digest: digest, callbacks: [deliver])
        lock.unlock()
        return true
    }

    func finish(request: [String: Any], identity: [String: Any], report: [String: Any]) {
        guard let requestID = request["request_id"] as? String,
              let digest = request["patch_digest"] as? String else { return }
        lock.lock()
        guard var entry = entries[requestID], entry.digest == digest, entry.report == nil else {
            lock.unlock(); return
        }
        var result = report
        result["request_id"] = requestID
        result["patch_digest"] = digest
        result["client_identity"] = identity
        result["root_revision"] = report["root_revision"] ?? report["revision"] ?? 0
        result["refreshed"] = report["refresh_acknowledged"] as? Bool == true
        entry.report = result
        let callbacks = entry.callbacks
        entry.callbacks.removeAll()
        entries[requestID] = entry
        lock.unlock()
        callbacks.forEach { $0(result) }
    }

    private static func failure(_ code: String, request: [String: Any], identity: [String: Any], noEffect: Bool) -> [String: Any] {
        var result: [String: Any] = ["succeeded": false, "applied": false, "refreshed": false,
         "refresh_acknowledged": false, "root_revision": 0, "error_code": code,
         "admission": noEffect ? "rejected-no-effect" : "rejected",
         "request_id": request["request_id"] as? String ?? "",
         "patch_digest": request["patch_digest"] as? String ?? "",
         "client_identity": identity]
        if noEffect { result["attempt_id"] = request["attempt_id"] as? String ?? "" }
        return result
    }
}
#endif
