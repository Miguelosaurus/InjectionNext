import XCTest
@testable import InjectionBundle

final class PreparedDeliveryTests: XCTestCase {
    private let identity: [String: Any] = ["bundle_id": "example.fixture", "build_number": "7",
        "executable_uuid": "fixture-executable", "debug_dylib_uuid": "fixture-debug",
        "process_nonce": "fixture-process", "connection_nonce": "fixture-connection",
        "root_revision": 4, "root_ready": true, "is_active": true]
    private let bytes = Data("signed-fixture".utf8)
    private func request(_ data: Data, id: String = UUID().uuidString) -> [String: Any] {
        ["request_id": id, "patch_digest": PreparedDeliveryLedger.digest(data),
         "expires_at_ms": 2_000.0, "baseline_revision": 4, "attempt_id": "fixture-attempt", "expected_identity": identity]
    }

    func testOneOwnerAndDuplicateReceiptAfterReconnect() {
        let ledger = PreparedDeliveryLedger()
        let value = request(bytes)
        var reports: [[String: Any]] = []
        XCTAssertTrue(ledger.begin(request: value, data: bytes, identity: identity, now: 1_000) { reports.append($0) })
        XCTAssertFalse(ledger.begin(request: value, data: bytes, identity: identity, now: 1_000) { reports.append($0) })
        ledger.finish(request: value, identity: identity,
            report: ["applied": true, "refresh_acknowledged": true, "revision": 5, "succeeded": true])
        XCTAssertEqual(reports.count, 2)
        var reconnected = identity
        reconnected["connection_nonce"] = "replacement-connection"
        reconnected["root_revision"] = 5
        XCTAssertFalse(ledger.begin(request: value, data: bytes, identity: reconnected, now: 1_000) { reports.append($0) })
        XCTAssertEqual(reports.count, 3)
        XCTAssertEqual(reports.last?["root_revision"] as? Int, 5)
        XCTAssertEqual(reports.last?["request_id"] as? String, value["request_id"] as? String)
        XCTAssertEqual(reports.last?["patch_digest"] as? String, value["patch_digest"] as? String)
    }

    func testNoDuplicateRefreshOnRepeatedCompletion() {
        let ledger = PreparedDeliveryLedger()
        let value = request(bytes)
        var completions = 0
        XCTAssertTrue(ledger.begin(request: value, data: bytes, identity: identity, now: 1_000) { _ in completions += 1 })
        ledger.finish(request: value, identity: identity, report: ["applied": true, "refresh_acknowledged": true, "revision": 5])
        ledger.finish(request: value, identity: identity, report: ["applied": true, "refresh_acknowledged": true, "revision": 6])
        XCTAssertEqual(completions, 1)
    }

    func testBinaryAndProcessFencesRejectWithoutAnOwner() {
        for key in ["bundle_id", "build_number", "executable_uuid", "debug_dylib_uuid", "process_nonce"] {
            let ledger = PreparedDeliveryLedger()
            let value = request(bytes)
            var wrong = identity
            wrong[key] = "other"
            var code: String?
            XCTAssertFalse(ledger.begin(request: value, data: bytes, identity: wrong, now: 1_000) { code = $0["error_code"] as? String })
            XCTAssertEqual(code, "PREPARED_IDENTITY_MISMATCH")
            XCTAssertTrue(ledger.begin(request: value, data: bytes, identity: identity, now: 1_000) { _ in })
        }
    }

    func testPreAdmissionForegroundRejectionIsAttemptBoundAndRetryable() {
        let ledger = PreparedDeliveryLedger()
        let value = request(bytes)
        var inactive = identity; inactive["is_active"] = false
        var rejection: [String: Any]?
        XCTAssertFalse(ledger.begin(request: value, data: bytes, identity: inactive, now: 1_000) { rejection = $0 })
        XCTAssertEqual(rejection?["admission"] as? String, "rejected-no-effect")
        XCTAssertEqual(rejection?["attempt_id"] as? String, "fixture-attempt")
        var retry = value; retry["attempt_id"] = "next-attempt"
        XCTAssertTrue(ledger.begin(request: retry, data: bytes, identity: identity, now: 1_000) { _ in })
    }

    func testWrongSignedBytesAreRejected() {
        var code: String?
        XCTAssertFalse(PreparedDeliveryLedger().begin(request: request(bytes), data: Data("other".utf8), identity: identity, now: 1_000) { code = $0["error_code"] as? String })
        XCTAssertEqual(code, "PREPARED_DIGEST_MISMATCH")
    }

    func testForegroundAndRootReadinessAreRequiredBeforeNewApply() {
        for key in ["is_active", "root_ready"] {
            let ledger = PreparedDeliveryLedger()
            let value = request(bytes)
            var notReady = identity; notReady[key] = false
            var code: String?
            XCTAssertFalse(ledger.begin(request: value, data: bytes, identity: notReady, now: 1_000) { code = $0["error_code"] as? String })
            XCTAssertEqual(code, "PREPARED_WAITING_FOR_FOREGROUND")
            XCTAssertTrue(ledger.begin(request: value, data: bytes, identity: identity, now: 1_000) { _ in })
        }
    }

    func testBaselineMustMatchForFirstApplyButNotReceiptReplay() {
        let ledger = PreparedDeliveryLedger()
        let value = request(bytes)
        var stale = identity; stale["root_revision"] = 9
        var code: String?
        XCTAssertFalse(ledger.begin(request: value, data: bytes, identity: stale, now: 1_000) { code = $0["error_code"] as? String })
        XCTAssertEqual(code, "PREPARED_BASELINE_MISMATCH")
    }

    func testRequestIdentityCannotBeReusedForDifferentBytes() {
        let ledger = PreparedDeliveryLedger()
        let value = request(bytes)
        XCTAssertTrue(ledger.begin(request: value, data: bytes, identity: identity, now: 1_000) { _ in })
        let other = Data("different".utf8)
        let conflicting = request(other, id: value["request_id"] as! String)
        var code: String?
        XCTAssertFalse(ledger.begin(request: conflicting, data: other, identity: identity, now: 1_000) { code = $0["error_code"] as? String })
        XCTAssertEqual(code, "PREPARED_REQUEST_CONFLICT")
    }

    func testExpiryAndUnboundedLifetimeAreRejected() {
        for expiry in [999.0, 100_000_000.0, Double.infinity] {
            var value = request(bytes); value["expires_at_ms"] = expiry
            var code: String?
            XCTAssertFalse(PreparedDeliveryLedger().begin(request: value, data: bytes, identity: identity, now: 1_000) { code = $0["error_code"] as? String })
            XCTAssertEqual(code, "PREPARED_REQUEST_INVALID_OR_EXPIRED")
        }
    }

    func testCapacityNeverEvictsAReceiptIntoASecondApply() {
        let ledger = PreparedDeliveryLedger(capacity: 1)
        let first = request(bytes)
        XCTAssertTrue(ledger.begin(request: first, data: bytes, identity: identity, now: 1_000) { _ in })
        ledger.finish(request: first, identity: identity, report: ["applied": true, "revision": 5])
        var code: String?
        XCTAssertFalse(ledger.begin(request: request(bytes), data: bytes, identity: identity, now: 1_000) { code = $0["error_code"] as? String })
        XCTAssertEqual(code, "PREPARED_RECEIPT_CAPACITY")
        XCTAssertFalse(ledger.begin(request: first, data: bytes, identity: identity, now: 1_000) { _ in })
    }

    func testParallelTransportRetriesHaveOnlyOneOwner() {
        let ledger = PreparedDeliveryLedger()
        let value = request(bytes)
        let lock = NSLock(); var owners = 0
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            if ledger.begin(request: value, data: bytes, identity: identity, now: 1_000, deliver: { _ in }) {
                lock.lock(); owners += 1; lock.unlock()
            }
        }
        XCTAssertEqual(owners, 1)
    }
}
