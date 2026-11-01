import Foundation

@main
struct DeveloperToolTests {
    static func require(_ condition: Bool, _ reason: String) {
        if !condition { fatalError(reason) }
    }
    static func main() {
        captureTests()
        queuedToolTests()
        var now: TimeInterval = 100
        let ledger = DeveloperToolLedger(clock: { now })
        var results: [[String: Any]] = []
        require(ledger.begin(id: "refresh", tool: "refresh", value: nil, reply: { results.append($0) }), "first operation owns UI request")
        require(!ledger.begin(id: "other", tool: "appearance", value: "dark", reply: { results.append($0) }), "only one UI mutation pending")
        require(results.last?["error"] as? String == "DEVELOPER_BUSY", "busy explicitly returned")
        require(!ledger.begin(id: "refresh", tool: "refresh", value: nil, reply: { results.append($0) }), "duplicate never emits second UI action")
        require(!ledger.complete(id: "stale", result: ["success": true]), "unrelated completion refused")
        require(ledger.complete(id: "refresh", result: ["success": true, "raw_secret": "omitted"]), "own completed operation accepted")
        require(results.last?["presentation_only"] as? Bool == true, "refresh explicitly remains presentation-only")
        require(results.last?["raw_secret"] == nil, "result allowlist drops arbitrary payload")
        require(!ledger.complete(id: "refresh", result: ["success": true]), "completion cannot be repeated")
        let before = results.count
        require(!ledger.begin(id: "refresh", tool: "refresh", value: nil, reply: { results.append($0) }), "cached UUID cannot reexecute on reconnect")
        require(results.count == before + 1 && results.last?["success"] as? Bool == true, "duplicate returns exact completion")
        require(!ledger.begin(id: "refresh", tool: "appearance", value: "dark", reply: { results.append($0) }), "UUID cannot be repurposed")
        require(results.last?["error"] as? String == "DEVELOPER_TOOL_CONFLICT", "changed intention conflict returned")
        require(ledger.begin(id: "slow", tool: "appearance", value: "dark", reply: { results.append($0) }), "next explicit operation admitted")
        now += 11
        require(!ledger.complete(id: "slow", result: ["success": true]), "late completion cannot claim timely success")
        require(!ledger.begin(id: "slow", tool: "appearance", value: "dark", reply: { results.append($0) }), "expired unknown operation cannot replay")
        require(results.last?["error"] as? String == "DEVELOPER_TOOL_UNCONFIRMED", "expiry preserves uncertainty")
        require(ledger.begin(id: "next", tool: "appearance", value: "app-default", reply: { results.append($0) }), "expired operation does not strand future explicit actions")
        require(ledger.complete(id: "next", result: ["success": false, "error": "/private/path"]), "failure delivered")
        require(results.last?["error"] as? String == "DEVELOPER_TOOL_UNAVAILABLE", "unsafe error text is not exported")

        let concurrent = DeveloperToolLedger()
        let lock = NSLock(); var accepted = 0
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if concurrent.begin(id: "same", tool: "refresh", value: nil, reply: { _ in }) {
                lock.lock(); accepted += 1; lock.unlock()
            }
        }
        require(accepted == 1, "32 racing identical requests admit one UI mutation")
        require(concurrent.complete(id: "same", result: ["success": true]), "racing owner completes once")
        print("Developer tool at-most-once, stale reply, uncertainty and concurrency checks passed")
    }

    static func queuedToolTests() {
        var now: TimeInterval = 10
        let ledger = DeveloperToolLedger(clock: { now })
        var lastResult: [String: Any] = [:]
        require(ledger.begin(id: "queued", tool: "refresh", value: nil, reply: { lastResult = $0 }), "queued action admitted")
        now += 11
        var effects = 0
        if ledger.claim(id: "queued", tool: "refresh", value: nil) != nil { effects += 1 }
        require(effects == 0, "blocked-main queued action emits no UI event after expiry")
        require(lastResult["error"] as? String == "DEVELOPER_TOOL_UNCONFIRMED", "expired queued action reports uncertainty without effect")
        require(ledger.begin(id: "fresh", tool: "appearance", value: "dark", reply: { _ in }), "fresh UI request admitted")
        require(ledger.claim(id: "fresh", tool: "appearance", value: "dark") != nil, "timely action claims main dispatch once")
        require(ledger.claim(id: "fresh", tool: "appearance", value: "dark") == nil, "already dispatched action cannot emit twice")
        require(ledger.complete(id: "fresh", result: ["success": true]), "claimed action completes")
        require(ledger.claim(id: "fresh", tool: "appearance", value: "dark") == nil, "completed action cannot emit another event")
        print("Queued developer tool deadline and one-dispatch checks passed")
    }

    static func captureTests() {
        let blocked = DispatchQueue(label: "BlockedCaptureFixture")
        let release = DispatchSemaphore(value: 0)
        let ticket = DeveloperCaptureTicket<Int>(timeout: 0.02)
        var draws = 0
        blocked.async { release.wait() }
        blocked.async {
            guard ticket.begin() else { return }
            draws += 1; ticket.finish(7)
        }
        let start = ProcessInfo.processInfo.systemUptime
        require(ticket.wait() == nil, "blocked main equivalent times out")
        require(ProcessInfo.processInfo.systemUptime - start < 0.5, "capture reader is not wedged by queued UI work")
        release.signal(); blocked.sync {}
        require(draws == 0, "late queued capture does no hierarchy draw")
        require(!ticket.begin(), "cancelled ticket cannot be revived")

        var now: TimeInterval = 10
        let expired = DeveloperCaptureTicket<Int>(timeout: 0.5, clock: { now })
        require(expired.begin(), "timely capture begins once")
        now += 1
        expired.finish(9)
        require(expired.wait() == nil, "late draw completion cannot retain or publish pixels")
        let timely = DeveloperCaptureTicket<Int>()
        require(timely.begin(), "fresh ticket begins")
        timely.finish(11)
        require(timely.wait() == 11, "timely completed draw is returned")

        let identity: [String: Any] = ["bundle_id": "example.fixture", "executable_uuid": "exec",
            "debug_dylib_uuid": "debug", "process_nonce": "process", "connection_nonce": "connection",
            "root_revision": 4, "is_active": true]
        require(DeveloperCaptureEvidence.isCurrent(identity, identity, sequence: 3, currentSequence: 3, pending: false), "exact capture evidence admitted")
        for key in ["bundle_id", "executable_uuid", "debug_dylib_uuid", "process_nonce", "connection_nonce"] {
            var changed = identity; changed[key] = "changed"
            require(!DeveloperCaptureEvidence.isCurrent(identity, changed, sequence: 3, currentSequence: 3, pending: false), "capture identity change refused: " + key)
        }
        var revision = identity; revision["root_revision"] = 5
        require(!DeveloperCaptureEvidence.isCurrent(identity, revision, sequence: 3, currentSequence: 3, pending: false), "newer code cannot inherit older image identity")
        require(!DeveloperCaptureEvidence.isCurrent(identity, identity, sequence: 3, currentSequence: 4, pending: false), "changed delivery phase invalidates image even before revision advances")
        require(!DeveloperCaptureEvidence.isCurrent(identity, identity, sequence: 3, currentSequence: 3, pending: true), "pending native application invalidates image")
        print("Capture timeout cancellation and exact revision/phase fences passed")
    }
}
