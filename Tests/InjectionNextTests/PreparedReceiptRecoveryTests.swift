import XCTest
@testable import InjectionBundle

final class PreparedReceiptRecoveryTests: XCTestCase {
    private let bytes = Data("receipt-recovery-fixture".utf8)
    private let identity: [String: Any] = ["bundle_id": "example.recovery", "build_number": "1",
        "executable_uuid": "fixture-executable", "debug_dylib_uuid": "fixture-debug",
        "process_nonce": "fixture-process", "connection_nonce": "first-connection",
        "root_revision": 0, "root_ready": true, "is_active": true]
    private func request() -> [String: Any] {
        ["request_id": UUID().uuidString, "patch_digest": PreparedDeliveryLedger.digest(bytes),
         "expires_at_ms": 2000.0, "baseline_revision": 0, "attempt_id": "original-attempt",
         "expected_identity": identity, "refresh_strategy": "preserve-state-v1",
         "replacement_proof": ["version": 3, "swift_replacements": 1, "objc_callbacks": []]]
    }
    private func complete(_ ledger: PreparedDeliveryLedger, _ request: [String: Any]) {
        ledger.finish(request: request, identity: identity,
                      report: ["succeeded": true, "applied": true, "refresh_acknowledged": true,
                               "root_revision": 1, "refresh_strategy": "preserve-state-v1"])
    }
    private func reconnect() -> [String: Any] {
        var value = identity; value["connection_nonce"] = "second-connection"; value["root_revision"] = 1
        return value
    }
    func testCompletedLookupRecoversLostAcknowledgementWithoutApplyOrRefresh() {
        let ledger = PreparedDeliveryLedger(), request = request()
        var owners = 0, originalReports = 0
        if ledger.begin(request: request, data: bytes, identity: identity, now: 1000, deliver: { _ in originalReports += 1 }) { owners += 1 }
        complete(ledger, request)
        let current = reconnect(); var query = request; query["connection_nonce"] = current["connection_nonce"]
        for _ in 0..<32 {
            var result: [String: Any]?
            XCTAssertTrue(ledger.recoverReceipt(request: query, identity: current) { result = $0 })
            XCTAssertEqual(result?["root_revision"] as? Int, 1)
            XCTAssertEqual(result?["request_id"] as? String, request["request_id"] as? String)
        }
        XCTAssertEqual(owners, 1); XCTAssertEqual(originalReports, 1)
        XCTAssertFalse(ledger.begin(request: request, data: bytes, identity: current, now: 1000) { _ in })
    }
    func testPendingLookupAttachesToOneExistingCompletionAndIsBounded() {
        let ledger = PreparedDeliveryLedger(), request = request()
        XCTAssertTrue(ledger.begin(request: request, data: bytes, identity: identity, now: 1000) { _ in })
        var query = request; query["connection_nonce"] = "second-connection"
        let lock = NSLock(); var attached = 0, replies = 0
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if ledger.recoverReceipt(request: query, identity: reconnect(), deliver: { _ in lock.lock(); replies += 1; lock.unlock() }) {
                lock.lock(); attached += 1; lock.unlock()
            }
        }
        XCTAssertEqual(attached, 15) // existing original callback + recovery <= 16
        complete(ledger, request); complete(ledger, request)
        XCTAssertEqual(replies, 15)
    }
    func testUnknownLookupCannotReserveOrLoadAndIgnoresExpiryForExistingReceipts() {
        let ledger = PreparedDeliveryLedger(), request = request()
        var query = request; query["connection_nonce"] = "second-connection"
        XCTAssertFalse(ledger.recoverReceipt(request: query, identity: reconnect()) { _ in XCTFail("unknown has no receipt") })
        XCTAssertTrue(ledger.begin(request: request, data: bytes, identity: identity, now: 1000) { _ in })
        complete(ledger, request)
        query["expires_at_ms"] = -1 // reading a cached result has no admission deadline
        XCTAssertTrue(ledger.recoverReceipt(request: query, identity: reconnect()) { XCTAssertEqual($0["root_revision"] as? Int, 1) })
    }
    func testConflictingOperationAndIdentityNeverBorrowReceipt() {
        let ledger = PreparedDeliveryLedger(), request = request()
        XCTAssertTrue(ledger.begin(request: request, data: bytes, identity: identity, now: 1000) { _ in }); complete(ledger, request)
        var query = request; query["connection_nonce"] = "second-connection"
        let mutations: [[String: Any]] = [["patch_digest": String(repeating: "a", count: 64)], ["attempt_id": "other"],
            ["baseline_revision": 9], ["refresh_strategy": "remount"], ["connection_nonce": "stale"],
            ["replacement_proof": ["version": 3, "swift_replacements": 2, "objc_callbacks": []]]]
        for mutation in mutations {
            var invalid = query; mutation.forEach { invalid[$0.key] = $0.value }
            XCTAssertFalse(ledger.recoverReceipt(request: invalid, identity: reconnect()) { _ in XCTFail("conflict") })
        }
        for key in ["bundle_id", "build_number", "executable_uuid", "debug_dylib_uuid", "process_nonce"] {
            var wrong = reconnect(); wrong[key] = "different"
            XCTAssertFalse(ledger.recoverReceipt(request: query, identity: wrong) { _ in XCTFail("wrong identity") })
            var changed = identity; changed[key] = "different"; var invalid = query; invalid["expected_identity"] = changed
            XCTAssertFalse(ledger.recoverReceipt(request: invalid, identity: reconnect()) { _ in XCTFail("wrong expected identity") })
        }
    }
}
