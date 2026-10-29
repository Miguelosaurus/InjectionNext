import Cocoa
import CryptoKit
import Security

/// Private Unix-socket preparation and delivery. This deliberately does not
/// change the legacy interactive injection commands or bypass code signing.
enum PreparedDeliveryEngine {
    static let instanceNonce = UUID().uuidString.lowercased()
    private struct Receipt {
        let digest: String
        let processNonce: String
        var attemptID: String
        var report: [String: Any]?
    }
    private static let queue = DispatchQueue(label: "SwiftSimPreparedReceipts")
    private static var receipts: [String: Receipt] = [:]
    static let capabilities = ["prepared-delivery-v1", "reconnect-v1", "receipt-v1"]

    static func prepare(_ params: [String: Any]) -> ControlServer.ActionResult {
        guard let path = artifact(params["path"] as? String) else { return .fail("PREPARED_ARTIFACT_INVALID") }
        let platform = params["platform"] as? String ?? "iPhoneOS"
        guard ["iPhoneOS", "iPhoneSimulator", "MacOSX"].contains(platform) else { return .fail("PREPARED_PLATFORM_INVALID") }
        let identity = Thread.isMainThread ? ConfigStore.shared.codesigningIdentity ?? ""
            : DispatchQueue.main.sync { ConfigStore.shared.codesigningIdentity ?? "" }
        guard !identity.isEmpty else { return .fail("PREPARED_SIGNING_IDENTITY_MISSING") }
        if !signatureMatches(path: path, identity: identity, platform: platform) {
            guard runCodesign(["--force", "--sign", platform.hasSuffix("Simulator") ? "-" : identity,
                               "--timestamp=none", path]) else { return .fail("PREPARED_SIGNING_FAILED") }
        }
        guard signatureMatches(path: path, identity: identity, platform: platform),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              !data.isEmpty, data.count <= 256 * 1_024 * 1_024 else { return .fail("PREPARED_SIGNATURE_INVALID") }
        return .ok(["patch_digest": digest(data), "size_bytes": data.count, "signed": true,
                    "engine_instance_nonce": instanceNonce])
    }

    static func inject(_ params: [String: Any]) -> ControlServer.ActionResult {
        guard let requestID = params["request_id"] as? String, UUID(uuidString: requestID) != nil,
              let patchDigest = params["patch_digest"] as? String, isDigest(patchDigest),
              let expiry = params["expires_at_ms"] as? Double, expiry.isFinite,
              expiry > now, expiry <= now + 86_400_000,
              let baseline = params["baseline_revision"] as? Int, baseline >= 0,
              let attemptID = params["attempt_id"] as? String, !attemptID.isEmpty, attemptID.utf8.count <= 128,
              let expected = params["expected_identity"] as? [String: Any],
              let processNonce = expected["process_nonce"] as? String else { return .fail("PREPARED_REQUEST_INVALID_OR_EXPIRED") }
        guard let (client, metadata) = InjectionServer.preparedTarget(),
              let identity = metadata["identity"] as? [String: Any],
              let clientCapabilities = metadata["capabilities"] as? [String],
              Set(capabilities).isSubset(of: Set(clientCapabilities)) else { return .fail("PREPARED_CLIENT_UNAVAILABLE") }
        for key in ["bundle_id", "build_number", "executable_uuid", "debug_dylib_uuid", "process_nonce"] {
            guard let value = expected[key] as? String, !value.isEmpty,
                  value == identity[key] as? String else { return .fail("PREPARED_IDENTITY_MISMATCH") }
        }
        guard identity["is_active"] as? Bool == true, identity["root_ready"] as? Bool == true else { return .fail("PREPARED_WAITING_FOR_FOREGROUND") }
        guard let path = artifact(params["path"] as? String),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              !data.isEmpty, data.count <= 256 * 1_024 * 1_024, digest(data) == patchDigest else { return .fail("PREPARED_DIGEST_MISMATCH") }
        let key = processNonce + ":" + requestID
        let admitted: Bool = queue.sync {
            if let receipt = receipts[key] { return receipt.digest == patchDigest }
            guard receipts.count < 1_024 else { return false }
            receipts[key] = Receipt(digest: patchDigest, processNonce: processNonce, attemptID: attemptID)
            return true
        }
        guard admitted else { return .fail("PREPARED_RECEIPT_CONFLICT_OR_CAPACITY") }
        if let receipt = receipt(requestID: requestID, digest: patchDigest, processNonce: processNonce), receipt["state"] as? String == "completed" {
            return .ok(receipt)
        }
        queue.sync {
            receipts[key]?.attemptID = attemptID
            if receipts[key]?.report?["admission"] as? String == "rejected-no-effect" {
                receipts[key]?.report = nil
            }
        }
        let envelope: [String: Any] = ["request_id": requestID, "patch_digest": patchDigest,
            "expires_at_ms": expiry, "baseline_revision": baseline, "attempt_id": attemptID, "expected_identity": expected]
        guard let encoded = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: encoded, encoding: .utf8) else { return .fail("PREPARED_REQUEST_INVALID") }
        InjectionServer.clientQueue.async {
            // The captured client owns this write. A new connection cannot be
            // substituted after identity validation or between command/data.
            _ = client.writePrepared(command: InjectionCommand.preparedInject.rawValue,
                                     metadata: json, data: data, timeout: 3.0)
            // A failed/partial write disconnects that captured socket but keeps
            // the receipt pending: transport failure is not proof of no apply.
        }
        return .ok(["request_id": requestID, "patch_digest": patchDigest, "state": "pending",
                    "client_identity": identity, "engine_instance_nonce": instanceNonce])
    }

    static func record(_ report: [String: Any], from client: InjectionServer) {
        guard let metadata = client.preparedMetadata(), let identity = metadata["identity"] as? [String: Any],
              let reportIdentity = report["client_identity"] as? [String: Any],
              let processNonce = identity["process_nonce"] as? String,
              reportIdentity["process_nonce"] as? String == processNonce,
              let requestID = report["request_id"] as? String,
              let patchDigest = report["patch_digest"] as? String else { return }
        let key = processNonce + ":" + requestID
        queue.sync {
            guard var receipt = receipts[key], receipt.digest == patchDigest,
                  receipt.report == nil || receipt.report?["admission"] as? String == "rejected-no-effect" else { return }
            // Only the authenticated client's explicit pre-admission proof may
            // make this request retryable. applied:false alone is insufficient.
            if report["admission"] as? String == "rejected-no-effect" {
                guard report["attempt_id"] as? String == receipt.attemptID,
                      report["applied"] as? Bool == false,
                      report["refresh_acknowledged"] as? Bool == false,
                      ["PREPARED_WAITING_FOR_FOREGROUND", "PREPARED_BASELINE_MISMATCH"].contains(report["error_code"] as? String ?? "") else { return }
            }
            receipt.report = report
            receipts[key] = receipt
        }
    }

    static func query(_ params: [String: Any]) -> ControlServer.ActionResult {
        guard let requestID = params["request_id"] as? String, UUID(uuidString: requestID) != nil,
              let patchDigest = (params["patch_digest"] ?? params["digest"]) as? String, isDigest(patchDigest),
              let (_, metadata) = InjectionServer.preparedTarget(),
              let identity = metadata["identity"] as? [String: Any],
              let processNonce = identity["process_nonce"] as? String else { return .fail("PREPARED_CLIENT_UNAVAILABLE") }
        guard let value = receipt(requestID: requestID, digest: patchDigest, processNonce: processNonce) else {
            return .ok(["state": "unknown", "request_id": requestID, "patch_digest": patchDigest,
                        "client_identity": identity, "engine_instance_nonce": instanceNonce])
        }
        return .ok(value)
    }

    private static func receipt(requestID: String, digest: String, processNonce: String) -> [String: Any]? {
        queue.sync {
            guard let receipt = receipts[processNonce + ":" + requestID], receipt.digest == digest else { return nil }
            let state = receipt.report == nil ? "pending"
                : receipt.report?["admission"] as? String == "rejected-no-effect" ? "rejected-no-effect" : "completed"
            var result: [String: Any] = ["state": state, "request_id": requestID,
                    "patch_digest": digest, "process_nonce": processNonce, "engine_instance_nonce": instanceNonce]
            if let report = receipt.report { result["report"] = report }
            return result
        }
    }

    private static var now: Double { Date().timeIntervalSince1970 * 1_000 }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func isDigest(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase } }

    private static func artifact(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/"), path.hasSuffix(".dylib") else { return nil }
        let root = ProcessInfo.processInfo.environment["SWIFT_SIM_PREPARED_ROOT"] ?? NSHomeDirectory() + "/.swift-sim/live/queued-artifacts"
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
        guard let rootAttributes = try? FileManager.default.attributesOfItem(atPath: rootURL.path),
              rootAttributes[.type] as? FileAttributeType == .typeDirectory,
              (rootAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              let rootPermissions = rootAttributes[.posixPermissions] as? NSNumber,
              rootPermissions.intValue & 0o077 == 0 else { return nil }
        let input = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = input.resolvingSymlinksInPath()
        guard input.path == resolved.path, resolved.deletingLastPathComponent().path == rootURL.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else { return nil }
        return resolved.path
    }

    private static func signatureMatches(path: String, identity: String, platform: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return false }
        if platform.hasSuffix("Simulator") { return true }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first else { return false }
        let fingerprint = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02X", $0) }.joined()
        return fingerprint == identity.uppercased() || SecCertificateCopySubjectSummary(certificate) as String? == identity
    }

    private static func runCodesign(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return false }
        if finished.wait(timeout: .now() + .seconds(10)) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + .seconds(1))
            return false
        }
        return process.terminationStatus == 0
    }
}
