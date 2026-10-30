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

/// Local Debug presentation only. This channel never changes admission,
/// application, the root revision, or receipt ownership. In particular, a
/// loaded library or a presentation timer cannot publish a successful update.
final class PreparedDeliveryFeedback {
    static let shared = PreparedDeliveryFeedback()
    static let notification = Notification.Name("SWIFT_SIM_LIVE_DELIVERY_FEEDBACK")
    private struct Active {
        let requestID: String
        let digest: String
        let baseline: Int
        var rank: Int
    }
    private let lock = NSLock()
    private var active: Active?
    private var sequence = 0
    private let publish: ([String: Any]) -> Void

    init(publish: @escaping ([String: Any]) -> Void = {
        NotificationCenter.default.post(name: PreparedDeliveryFeedback.notification,
                                        object: nil, userInfo: $0)
    }) { self.publish = publish }

    func begin(_ request: [String: Any]) {
        guard let id = request["request_id"] as? String, UUID(uuidString: id) != nil,
              let digest = request["patch_digest"] as? String, digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let baseline = request["baseline_revision"] as? Int, baseline >= 0 else { return }
        lock.lock()
        active = Active(requestID: id, digest: digest, baseline: baseline, rank: 0)
        let event = eventLocked(phase: "receiving", rank: 0, request: request)
        lock.unlock()
        deliver(event)
    }

    func advance(_ request: [String: Any], phase: String) {
        let rank: Int
        switch phase {
        case "applying": rank = 1
        case "waiting-for-refresh": rank = 2
        default: return
        }
        lock.lock()
        let event = eventLocked(phase: phase, rank: rank, request: request)
        lock.unlock()
        deliver(event)
    }

    func finish(_ request: [String: Any], report: [String: Any]) {
        lock.lock()
        guard let current = active,
              current.requestID == request["request_id"] as? String,
              current.digest == request["patch_digest"] as? String else { lock.unlock(); return }
        let revision = report["root_revision"] as? Int ?? report["revision"] as? Int ?? 0
        let refreshed = report["applied"] as? Bool == true
            && (report["dynamic_replacements"] as? Int ?? 0) > 0
            && report["refresh_acknowledged"] as? Bool == true
            && revision > current.baseline
        var event = eventLocked(phase: refreshed ? "refreshed" : "failed", rank: 3, request: request)
        event?["applied"] = report["applied"] as? Bool == true
        event?["dynamic_replacements"] = report["dynamic_replacements"] as? Int ?? 0
        event?["refresh_acknowledged"] = report["refresh_acknowledged"] as? Bool == true
        event?["revision"] = revision
        lock.unlock()
        deliver(event)
    }

    private func eventLocked(phase: String, rank: Int, request: [String: Any]) -> [String: Any]? {
        guard var current = active,
              current.requestID == request["request_id"] as? String,
              current.digest == request["patch_digest"] as? String,
              current.rank <= rank, current.rank < 3 else { return nil }
        current.rank = rank
        active = current
        sequence += 1
        return ["schema_version": 1, "request_id": current.requestID,
                "patch_digest": current.digest, "baseline_revision": current.baseline,
                "phase": phase, "sequence": sequence]
    }

    private func deliver(_ event: [String: Any]?) {
        guard let event else { return }
        let publish = self.publish
        if Thread.isMainThread { publish(event) }
        else { DispatchQueue.main.async { publish(event) } }
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
    private let feedback: PreparedDeliveryFeedback?
    init(capacity: Int = 1_024, feedback: PreparedDeliveryFeedback? = .shared) {
        self.capacity = capacity; self.feedback = feedback
    }

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
        feedback?.begin(request)
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
        feedback?.finish(request, report: result)
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
