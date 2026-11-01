import Foundation

@main
struct DeveloperToolTests {
    static func require(_ condition: Bool, _ reason: String) {
        if !condition { fatalError(reason) }
    }
    static func main() {
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
}
