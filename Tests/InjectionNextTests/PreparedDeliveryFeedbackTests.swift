import XCTest
@testable import InjectionBundle

final class PreparedDeliveryFeedbackTests: XCTestCase {
    private let bytes = Data("qualified patch bytes".utf8)
    private func identity() -> [String: Any] {
        ["bundle_id": "example.feedback", "build_number": "1", "executable_uuid": "executable",
         "debug_dylib_uuid": "debug", "process_nonce": "process", "root_revision": 4,
         "root_ready": true, "is_active": true]
    }
    private func request(_ identity: [String: Any]) -> [String: Any] {
        ["request_id": UUID().uuidString, "patch_digest": PreparedDeliveryLedger.digest(bytes),
         "expires_at_ms": 2_000.0, "baseline_revision": 4, "attempt_id": "attempt",
         "expected_identity": identity]
    }

    func testAdmittedLifecycleIsCorrelatedAndReceiptsAloneCanConfirmRefresh() {
        var events: [[String: Any]] = []
        let feedback = PreparedDeliveryFeedback { XCTAssertTrue(Thread.isMainThread); events.append($0) }
        let ledger = PreparedDeliveryLedger(feedback: feedback)
        let identity = identity(); let request = request(identity)
        var receipts = 0
        XCTAssertTrue(ledger.begin(request: request, data: bytes, identity: identity, now: 1_000) { _ in receipts += 1 })
        feedback.advance(request, phase: "applying")
        feedback.advance(request, phase: "waiting-for-refresh")
        XCTAssertFalse(events.contains { $0["phase"] as? String == "refreshed" })
        ledger.finish(request: request, identity: identity, report: ["applied": true,
            "dynamic_replacements": 1, "refresh_acknowledged": true, "revision": 5])
        XCTAssertEqual(events.compactMap { $0["phase"] as? String }, ["receiving", "applying", "waiting-for-refresh", "refreshed"])
        XCTAssertTrue(events.allSatisfy { $0["request_id"] as? String == request["request_id"] as? String && $0["patch_digest"] as? String == request["patch_digest"] as? String })
        XCTAssertEqual(events.last?["revision"] as? Int, 5)
        XCTAssertEqual(receipts, 1)
        XCTAssertFalse(ledger.begin(request: request, data: bytes, identity: identity, now: 1_000) { _ in receipts += 1 })
        XCTAssertEqual(events.count, 4, "A receipt retry must not replay presentation")
        XCTAssertEqual(receipts, 2)
    }

    func testForegroundRejectionProducesNoUpdateFailureOrSuccessBanner() {
        var events: [[String: Any]] = []
        let feedback = PreparedDeliveryFeedback { events.append($0) }
        let ledger = PreparedDeliveryLedger(feedback: feedback)
        var identity = identity(); identity["is_active"] = false
        let request = request(identity)
        var rejection: [String: Any]?
        XCTAssertFalse(ledger.begin(request: request, data: bytes, identity: identity, now: 1_000) { rejection = $0 })
        XCTAssertEqual(rejection?["error_code"] as? String, "PREPARED_WAITING_FOR_FOREGROUND")
        XCTAssertTrue(events.isEmpty, "Normal app absence is not an in-app delivery failure")
    }

    func testLoadedOrUnacknowledgedOrStaleRevisionCannotPublishUpdated() {
        for mutation in [["applied": false], ["dynamic_replacements": 0], ["refresh_acknowledged": false], ["revision": 4]] as [[String: Any]] {
            var events: [[String: Any]] = []
            let feedback = PreparedDeliveryFeedback { events.append($0) }
            let ledger = PreparedDeliveryLedger(feedback: feedback)
            let identity = identity(); let request = request(identity)
            XCTAssertTrue(ledger.begin(request: request, data: bytes, identity: identity, now: 1_000) { _ in })
            var report: [String: Any] = ["applied": true, "dynamic_replacements": 1, "refresh_acknowledged": true, "revision": 5]
            report.merge(mutation) { _, next in next }
            ledger.finish(request: request, identity: identity, report: report)
            XCTAssertEqual(events.last?["phase"] as? String, "failed")
            XCTAssertFalse(events.contains { $0["phase"] as? String == "refreshed" })
        }
    }

    func testStaleRequestDigestAndRegressivePhaseCannotOverrideCurrentRequest() {
        var events: [[String: Any]] = []
        let feedback = PreparedDeliveryFeedback { events.append($0) }
        let identity = identity(); let a = request(identity); let b = request(identity)
        feedback.begin(a); feedback.advance(a, phase: "applying")
        feedback.begin(b)
        feedback.finish(a, report: ["applied": true, "dynamic_replacements": 1, "refresh_acknowledged": true, "revision": 5])
        var wrong = b; wrong["patch_digest"] = String(repeating: "f", count: 64)
        feedback.advance(wrong, phase: "applying")
        XCTAssertEqual(events.count, 3)
        feedback.advance(b, phase: "waiting-for-refresh")
        feedback.advance(b, phase: "applying")
        XCTAssertEqual(events.last?["phase"] as? String, "waiting-for-refresh")
    }

    func testBackgroundProducerPublishesOnMainThread() {
        let published = expectation(description: "main-thread local feedback")
        let feedback = PreparedDeliveryFeedback { event in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(event["phase"] as? String, "receiving")
            published.fulfill()
        }
        let input = request(identity())
        DispatchQueue.global().async { feedback.begin(input) }
        wait(for: [published], timeout: 2)
    }
}
