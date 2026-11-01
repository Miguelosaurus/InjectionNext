#if DEBUG || !SWIFT_PACKAGE
import Foundation

/// A bounded process-local ledger. Reconnecting cannot replay an accepted UI action.
/// The ledger is allocated only when a developer explicitly invokes a tool.
final class DeveloperToolLedger {
    static let shared = DeveloperToolLedger()
    private struct Entry {
        let tool: String
        let value: String?
        let expiry: TimeInterval
        var result: [String: Any]?
        var reply: (([String: Any]) -> Void)?
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let clock: () -> TimeInterval
    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }

    /// True means emit the one UI request; false means duplicate/refusal already replied.
    func begin(id: String, tool: String, value: String?, reply: @escaping ([String: Any]) -> Void) -> Bool {
        lock.lock()
        for (key, var entry) in entries where entry.result == nil && clock() > entry.expiry {
            entry.result = ["success": false, "error": "DEVELOPER_TOOL_UNCONFIRMED"]
            entry.reply = nil; entries[key] = entry
        }
        if var existing = entries[id] {
            guard existing.tool == tool, existing.value == value else {
                lock.unlock(); reply(["success": false, "error": "DEVELOPER_TOOL_CONFLICT"]); return false
            }
            if existing.result == nil && clock() > existing.expiry {
                existing.result = ["success": false, "error": "DEVELOPER_TOOL_UNCONFIRMED"]
                existing.reply = nil
            }
            if let result = existing.result {
                entries[id] = existing; lock.unlock(); reply(result); return false
            }
            existing.reply = reply; entries[id] = existing
            lock.unlock(); return false
        }
        guard entries.count < 256 else {
            lock.unlock(); reply(["success": false, "error": "DEVELOPER_TOOL_CAPACITY"]); return false
        }
        guard !entries.values.contains(where: { $0.result == nil && $0.expiry >= clock() }) else {
            lock.unlock(); reply(["success": false, "error": "DEVELOPER_BUSY"]); return false
        }
        entries[id] = Entry(tool: tool, value: value, expiry: clock() + 10, result: nil, reply: reply)
        lock.unlock(); return true
    }

    func complete(id: String, result input: [String: Any]) -> Bool {
        guard let success = input["success"] as? Bool else { return false }
        lock.lock()
        guard var entry = entries[id], entry.result == nil else { lock.unlock(); return false }
        guard clock() <= entry.expiry else {
            entry.result = ["success": false, "error": "DEVELOPER_TOOL_UNCONFIRMED"]
            entry.reply = nil; entries[id] = entry; lock.unlock(); return false
        }
        var result: [String: Any] = ["success": success, "tool": entry.tool]
        if entry.tool == "refresh" { result["presentation_only"] = true }
        if !success {
            let code = input["error"] as? String ?? "DEVELOPER_TOOL_UNAVAILABLE"
            result["error"] = code.hasPrefix("DEVELOPER_") && code.utf8.count <= 80 ? code : "DEVELOPER_TOOL_UNAVAILABLE"
        }
        let reply = entry.reply
        entry.result = result; entry.reply = nil; entries[id] = entry
        lock.unlock()
        reply?(result)
        return true
    }
}
#endif
