import XCTest
@testable import InjectionBundle

final class PreparedDeliveryV3Tests: XCTestCase {
    private let identity: [String: Any] = ["bundle_id": "example.v3", "build_number": "1",
        "executable_uuid": "executable", "debug_dylib_uuid": "debug", "process_nonce": "process",
        "root_revision": 1, "root_ready": true, "is_active": true]
    private let data = Data("v3 fixture".utf8)
    private func request() -> [String: Any] {
        ["request_id": UUID().uuidString, "patch_digest": PreparedDeliveryLedger.digest(data),
         "expires_at_ms": 2_000.0, "baseline_revision": 1, "attempt_id": "attempt-1", "expected_identity": identity,
         "replacement_proof": ["version": 3, "swift_replacements": 1, "objc_callbacks": []]]
    }
    func testPendingAndCachedClaimsBindCoverageAttemptAndBaseline() {
        for completed in [false, true] {
            for key in ["replacement_proof", "attempt_id", "baseline_revision"] {
                let ledger = PreparedDeliveryLedger(feedback: nil)
                let original = request()
                XCTAssertTrue(ledger.begin(request: original, data: data, identity: identity, now: 1_000) { _ in })
                if completed { ledger.finish(request: original, identity: identity, report: ["applied": false]) }
                var changed = original
                if key == "replacement_proof" { changed[key] = ["version": 3, "swift_replacements": 2, "objc_callbacks": []] }
                if key == "attempt_id" { changed[key] = "attempt-2" }
                if key == "baseline_revision" { changed[key] = 2 }
                var error: String?
                XCTAssertFalse(ledger.begin(request: changed, data: data, identity: identity, now: 1_000) { error = $0["error_code"] as? String })
                XCTAssertEqual(error, "PREPARED_REQUEST_CONFLICT", "\(key), cached=\(completed)")
            }
        }
    }
    func testStaleFinisherDoesNotResolveClaim() {
        for key in ["attempt_id", "baseline_revision", "replacement_proof"] {
            let ledger = PreparedDeliveryLedger(feedback: nil); let original = request()
            var reports = [[String: Any]]()
            XCTAssertTrue(ledger.begin(request: original, data: data, identity: identity, now: 1_000) { reports.append($0) })
            var changed = original
            if key == "attempt_id" { changed[key] = "stale" }
            if key == "baseline_revision" { changed[key] = 2 }
            if key == "replacement_proof" { changed[key] = ["version": 3, "swift_replacements": 2, "objc_callbacks": []] }
            ledger.finish(request: changed, identity: identity, report: ["applied": true])
            XCTAssertTrue(reports.isEmpty)
            ledger.finish(request: original, identity: identity, report: ["applied": false])
            XCTAssertEqual(reports.count, 1)
            XCTAssertEqual(reports[0]["attempt_id"] as? String, "attempt-1")
        }
    }
    func testChangedFreshIdentityCanNeverPublishSuccessOrNoEffect() {
        for key in ["bundle_id", "build_number", "executable_uuid", "debug_dylib_uuid", "process_nonce"] {
            let ledger = PreparedDeliveryLedger(feedback: nil); let original = request()
            var result: [String: Any]?
            XCTAssertTrue(ledger.begin(request: original, data: data, identity: identity, now: 1_000) { result = $0 })
            var changed = identity; changed[key] = "changed"
            ledger.finish(request: original, identity: changed, report: ["succeeded": true, "applied": true, "refresh_acknowledged": true, "root_revision": 2])
            XCTAssertEqual(result?["succeeded"] as? Bool, false)
            XCTAssertEqual(result?["admission"] as? String, "uncertain-after-load")
            XCTAssertEqual(result?["state_uncertain"] as? Bool, true)
            XCTAssertEqual(result?["refreshed"] as? Bool, false)
            XCTAssertEqual(result?["error_code"] as? String, "PREPARED_IDENTITY_CHANGED_AFTER_ADMISSION")
        }
    }
    func testCachedClaimCannotBeBorrowedByChangedExpectedIdentity() {
        let ledger = PreparedDeliveryLedger(feedback: nil); let original = request()
        XCTAssertTrue(ledger.begin(request: original, data: data, identity: identity, now: 1_000) { _ in })
        ledger.finish(request: original, identity: identity, report: ["applied": false])
        var changedIdentity = identity; changedIdentity["process_nonce"] = "other-process"
        var changed = original; changed["expected_identity"] = changedIdentity
        var code: String?
        XCTAssertFalse(ledger.begin(request: changed, data: data, identity: changedIdentity, now: 1_000) { code = $0["error_code"] as? String })
        XCTAssertEqual(code, "PREPARED_REQUEST_CONFLICT")
    }
    func testBooleanBaselineAndRootAreNotIntegers() {
        var original = request(); original["baseline_revision"] = true
        var code: String?
        XCTAssertFalse(PreparedDeliveryLedger(feedback: nil).begin(request: original, data: data, identity: identity, now: 1_000) { code = $0["error_code"] as? String })
        XCTAssertEqual(code, "PREPARED_REQUEST_INVALID_OR_EXPIRED")
        original = request(); var wrongRoot = identity; wrongRoot["root_revision"] = true
        XCTAssertFalse(PreparedDeliveryLedger(feedback: nil).begin(request: original, data: data, identity: wrongRoot, now: 1_000) { code = $0["error_code"] as? String })
        XCTAssertEqual(code, "PREPARED_BASELINE_MISMATCH")
    }
}
