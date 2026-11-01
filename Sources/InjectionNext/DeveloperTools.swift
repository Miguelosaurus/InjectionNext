#if DEBUG || !SWIFT_PACKAGE
import Foundation

enum DeveloperCaptureEvidence {
    static func sameIdentity(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        for key in ["bundle_id", "executable_uuid", "debug_dylib_uuid", "process_nonce", "connection_nonce"] {
            guard let value = lhs[key] as? String, value == rhs[key] as? String else { return false }
        }
        guard let revision = lhs["root_revision"] as? Int, revision >= 0,
              revision == rhs["root_revision"] as? Int else { return false }
        return lhs["is_active"] as? Bool == true && rhs["is_active"] as? Bool == true
    }

    static func isCurrent(_ captured: [String: Any], _ current: [String: Any],
                          sequence: Int, currentSequence: Int, pending: Bool) -> Bool {
        !pending && sequence == currentSequence && sameIdentity(captured, current)
    }
}

/// One request-scoped rendezvous. Expiry cancels queued capture work without
/// leaving the socket reader waiting on a blocked main thread.
final class DeveloperCaptureTicket<Value> {
    let deadline: TimeInterval
    private let clock: () -> TimeInterval
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var cancelled = false
    private var started = false
    private var finished = false
    private var value: Value?

    init(timeout: TimeInterval = 0.5,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock; deadline = clock() + timeout
    }

    var isValid: Bool {
        lock.lock(); defer { lock.unlock() }
        return !cancelled && clock() <= deadline
    }

    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !started, clock() <= deadline else { return false }
        started = true; return true
    }

    func finish(_ result: Value?) {
        lock.lock()
        guard !cancelled, !finished, clock() <= deadline else { lock.unlock(); return }
        finished = true; value = result
        lock.unlock(); semaphore.signal()
    }

    func wait() -> Value? {
        let remaining = max(0, deadline - clock())
        let completed = semaphore.wait(timeout: .now() + remaining) == .success
        lock.lock(); defer { lock.unlock() }
        defer { cancelled = true; value = nil }
        return completed && clock() <= deadline ? value : nil
    }
}

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
        var dispatched = false
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

    /// Called on main immediately before emitting the UI request. A queued
    /// block cannot acquire an expired, already completed, or dispatched action.
    func claim(id: String, tool: String, value: String?) -> TimeInterval? {
        lock.lock()
        guard var entry = entries[id], entry.tool == tool, entry.value == value,
              entry.result == nil, !entry.dispatched else { lock.unlock(); return nil }
        guard clock() <= entry.expiry else {
            let result: [String: Any] = ["success": false, "error": "DEVELOPER_TOOL_UNCONFIRMED"]
            let reply = entry.reply
            entry.result = result; entry.reply = nil; entries[id] = entry
            lock.unlock(); reply?(result); return nil
        }
        entry.dispatched = true; entries[id] = entry
        lock.unlock(); return entry.expiry
    }
}
#endif
