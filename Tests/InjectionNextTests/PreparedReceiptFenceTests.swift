import XCTest
@testable import InjectionBundle

final class PreparedReceiptFenceTests: XCTestCase {
    private let bytes = Data("receipt-fence".utf8)
    private let identity: [String: Any] = ["bundle_id": "example.fence", "build_number": "1",
        "executable_uuid": "executable", "debug_dylib_uuid": "debug", "process_nonce": "process",
        "connection_nonce": "new-connection", "root_revision": 0, "root_ready": true, "is_active": true]
    private func request(_ id: String = UUID().uuidString, attempt: String = "old") -> [String: Any] {
        ["request_id": id, "patch_digest": PreparedDeliveryLedger.digest(bytes), "expires_at_ms": 2000.0,
         "baseline_revision": 0, "attempt_id": attempt, "expected_identity": identity,
         "connection_nonce": "new-connection", "fence_unadmitted": true,
         "refresh_strategy": "preserve-state-v1",
         "replacement_proof": ["version": 3, "swift_replacements": 1, "objc_callbacks": []]]
    }
    private func complete(_ ledger: PreparedDeliveryLedger, _ request: [String: Any]) {
        ledger.finish(request: request, identity: identity, report: ["succeeded": true, "applied": true,
            "refresh_acknowledged": true, "root_revision": 1, "refresh_strategy": "preserve-state-v1"])
    }
    func testFenceBeforeAdmissionRefusesLateOldFrameAndAllowsOnlyOneNewOwner() {
        let ledger = PreparedDeliveryLedger(feedback: nil), old = request()
        for _ in 0..<3 {
            XCTAssertTrue(ledger.recoverReceipt(request: old, identity: identity) {
                XCTAssertEqual($0["attempt_fenced"] as? Bool, true)
                XCTAssertEqual($0["admission"] as? String, "rejected-no-effect")
                XCTAssertEqual($0["applied"] as? Bool, false)
            })
        }
        XCTAssertFalse(ledger.hasPending)
        XCTAssertFalse(ledger.begin(request: old, data: bytes, identity: identity, now: 1000) {
            XCTAssertEqual($0["error_code"] as? String, "PREPARED_ATTEMPT_FENCED")
        })
        var retry = old; retry["attempt_id"] = "new"
        XCTAssertTrue(ledger.begin(request: retry, data: bytes, identity: identity, now: 1000) { _ in })
        XCTAssertFalse(ledger.begin(request: old, data: bytes, identity: identity, now: 1000) { _ in })
        complete(ledger, retry)
        XCTAssertFalse(ledger.begin(request: retry, data: bytes, identity: identity, now: 1000) {
            XCTAssertEqual($0["root_revision"] as? Int, 1)
        })
        XCTAssertFalse(ledger.begin(request: old, data: bytes, identity: identity, now: 1000) { _ in })
    }
    func testAlreadyAdmittedLoadCannotBeCancelledByFenceQuery() {
        let ledger = PreparedDeliveryLedger(feedback: nil), old = request()
        XCTAssertTrue(ledger.begin(request: old, data: bytes, identity: identity, now: 1000) { _ in })
        var replied = false
        XCTAssertTrue(ledger.recoverReceipt(request: old, identity: identity) {
            replied = true
            XCTAssertNil($0["attempt_fenced"])
            XCTAssertEqual($0["applied"] as? Bool, true)
        })
        XCTAssertFalse(replied)
        complete(ledger, old)
        XCTAssertTrue(replied)
        var retry = old; retry["attempt_id"] = "new"
        XCTAssertFalse(ledger.begin(request: retry, data: bytes, identity: identity, now: 1000) { _ in })
    }
    func testConcurrentFenceAndAdmissionAlwaysHaveOneWinner() {
        for _ in 0..<100 {
            let ledger = PreparedDeliveryLedger(feedback: nil), old = request(), lock = NSLock()
            var originalOwner = false, fenced = false, owners = 0
            DispatchQueue.concurrentPerform(iterations: 2) { n in
                if n == 0 {
                    let owned = ledger.begin(request: old, data: bytes, identity: identity, now: 1000) { _ in }
                    lock.lock(); originalOwner = owned; if owned { owners += 1 }; lock.unlock()
                } else {
                    _ = ledger.recoverReceipt(request: old, identity: identity) { report in
                        lock.lock(); fenced = report["attempt_fenced"] as? Bool == true; lock.unlock()
                    }
                }
            }
            if originalOwner { complete(ledger, old) }
            else {
                XCTAssertTrue(fenced)
                var retry = old; retry["attempt_id"] = "new"
                if ledger.begin(request: retry, data: bytes, identity: identity, now: 1000, deliver: { _ in }) { owners += 1 }
                complete(ledger, retry)
            }
            XCTAssertEqual(owners, 1)
            XCTAssertFalse(ledger.begin(request: old, data: bytes, identity: identity, now: 1000) { _ in })
        }
    }
    func testRepeatedLostRetriesRetainEveryOldFenceAndAreBounded() {
        let ledger = PreparedDeliveryLedger(capacity: 1, feedback: nil), base = request()
        for n in 0..<16 {
            var query = base; query["attempt_id"] = "attempt-\(n)"
            XCTAssertTrue(ledger.recoverReceipt(request: query, identity: identity) { _ in })
        }
        var overflow = base; overflow["attempt_id"] = "attempt-16"
        XCTAssertFalse(ledger.recoverReceipt(request: overflow, identity: identity) { _ in XCTFail("bound") })
        XCTAssertFalse(ledger.recoverReceipt(request: request(), identity: identity) { _ in XCTFail("capacity") })
        for n in 0..<16 {
            var late = base; late["attempt_id"] = "attempt-\(n)"
            XCTAssertFalse(ledger.begin(request: late, data: bytes, identity: identity, now: 1000) {
                XCTAssertEqual($0["attempt_fenced"] as? Bool, true)
            })
        }
    }
    func testMissingReadOnlyLookupAndWrongContractsCannotFenceAnAttempt() {
        let base = request()
        let mutations: [[String: Any]] = [["connection_nonce": "stale"], ["baseline_revision": 1],
            ["refresh_strategy": "invalid"], ["replacement_proof": "invalid"]]
        for mutation in mutations {
            let ledger = PreparedDeliveryLedger(feedback: nil)
            var bad = base; mutation.forEach { bad[$0.key] = $0.value }
            XCTAssertFalse(ledger.recoverReceipt(request: bad, identity: identity) { _ in XCTFail("invalid") })
            XCTAssertTrue(ledger.begin(request: base, data: bytes, identity: identity, now: 1000) { _ in })
        }
        for key in ["bundle_id", "build_number", "executable_uuid", "debug_dylib_uuid", "process_nonce", "root_ready", "is_active"] {
            let ledger = PreparedDeliveryLedger(feedback: nil)
            var wrong = identity; wrong[key] = "different"
            XCTAssertFalse(ledger.recoverReceipt(request: base, identity: wrong) { _ in XCTFail("identity") })
            XCTAssertTrue(ledger.begin(request: base, data: bytes, identity: identity, now: 1000) { _ in })
        }
        for flag: Any? in [nil, false, 1, "true"] {
            let ledger = PreparedDeliveryLedger(feedback: nil)
            var legacy = base; legacy["fence_unadmitted"] = flag
            XCTAssertFalse(ledger.recoverReceipt(request: legacy, identity: identity) { _ in XCTFail("read only") })
            XCTAssertTrue(ledger.begin(request: base, data: bytes, identity: identity, now: 1000) { _ in })
        }
    }
}
