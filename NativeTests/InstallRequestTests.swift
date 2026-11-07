import Foundation
import Darwin

@main struct InstallRequestTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }
    static func main() throws {
        guard let resolved = realpath(CommandLine.arguments[1], nil) else { fatalError("test root unavailable") }
        let root = URL(fileURLWithPath: String(cString: resolved))
        free(resolved)
        var now: Double = 1000
        let id = UUID().uuidString.lowercased()
        let selector = ["bundle_id": "dev.test.app", "bundle_version": "1", "build_number": "4",
                        "executable_uuid": UUID().uuidString.lowercased(), "debug_dylib_uuid": UUID().uuidString.lowercased()]
        func payload(_ id: String, _ changes: [String: Any] = [:]) -> String {
            var value: [String: Any] = ["buildID": id, "bundleID": "dev.test.app", "version": "1", "build": "5",
                "sha256": String(repeating: "a", count: 64), "expiresAt": 2000,
                "manifestURL": "https://example.test/api/device-builds/\(id)/artifact/manifest?token=abcdefghijklmnopqrstuvwx"]
            value.merge(changes) { _, new in new }
            return String(data: try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys), encoding: .utf8)!
        }
        let value = payload(id)
        let intent = DeveloperInstallIntent.parse(value, bundleID: "dev.test.app", now: now)
        check(intent != nil && intent?.installURL?.scheme == "itms-services", "valid narrow install")
        for changes: [String: Any] in [["bundleID": "other"], ["expiresAt": 999], ["expiresAt": 99999], ["sha256": "bad"],
            ["manifestURL": "https://example.test/other"], ["manifestURL": "file:///app"],
            ["manifestURL": "https://user:secret@example.test/api/device-builds/\(id)/artifact/manifest?token=abcdefghijklmnopqrstuvwx"],
            ["manifestURL": "https://example.test/api/device-builds/\(id)/artifact/manifest?token=abcdefghijklmnopqrstuvwx&token=abcdefghijklmnopqrstuvwx"]] {
            check(DeveloperInstallIntent.parse(payload(id, changes), bundleID: "dev.test.app", now: now) == nil, "invalid install rejected")
        }
        let path = root.appendingPathComponent("queue.json")
        let queue = try InstallRequestQueue(path: path, now: { now })
        var sends = 0; var ready = false
        queue.inspect = { _ in ready ? .ready { sends += 1; return true } : .waiting }
        _ = try queue.enqueue(id: id, selector: selector, value: value)
        let entry = try queue.status(id)!
        var observed: [String: Any] = selector
        observed["is_active"] = true; observed["root_ready"] = true
        let capabilities = ["foreground-install-v1"]
        check(InstallRequestQueue.eligible(entry, identity: observed, capabilities: capabilities, pendingReload: false), "foreground exact identity admitted")
        check(!InstallRequestQueue.eligible(entry, identity: observed, capabilities: capabilities, pendingReload: true), "hot reload has priority")
        check(!InstallRequestQueue.eligible(entry, identity: observed, capabilities: [], pendingReload: false), "capability required")
        for key in ["is_active", "root_ready", "build_number", "bundle_id", "executable_uuid", "debug_dylib_uuid"] {
            var different = observed; different[key] = key == "is_active" || key == "root_ready" ? false : "other"
            check(!InstallRequestQueue.eligible(entry, identity: different, capabilities: capabilities, pendingReload: false), "wrong identity or background refused")
        }
        for _ in 0..<10 { queue.drain() }
        check(sends == 0, "locked/offline sends nothing")
        let reloaded = try InstallRequestQueue(path: path, now: { now })
        check(try! reloaded.status(id)?.state == "waiting", "pending survives restart")
        ready = true
        DispatchQueue.concurrentPerform(iterations: 32) { _ in queue.drain() }
        check(sends == 1, "32 races send once")
        check(try! queue.status(id)?.state == "prompt-requested", "handoff not install proof")
        _ = try queue.enqueue(id: id, selector: selector, value: value)
        queue.drain(); check(sends == 1, "duplicate same request never reopens")
        let after = try InstallRequestQueue(path: path, now: { now })
        after.inspect = { _ in .ready { sends += 1; return true } }; after.drain()
        check(sends == 1, "completed restart cannot resend")
        do { _ = try queue.enqueue(id: id, selector: selector, value: payload(id, ["build": "6"])); fatalError("conflict accepted") } catch {}
        let unknownID = UUID().uuidString.lowercased()
        _ = try queue.enqueue(id: unknownID, selector: selector, value: payload(unknownID))
        queue.inspect = { _ in .ready {
            // Simulate process death immediately after the durable handoff fence.
            let recovered = try! InstallRequestQueue(path: path, now: { now })
            recovered.inspect = { _ in .ready { sends += 1; return true } }
            recovered.drain()
            check(try! recovered.status(unknownID)?.state == "unconfirmed", "crashed handoff remains uncertain")
            sends += 1; return nil
        } }
        queue.drain(); queue.drain()
        check(sends == 2 && (try! queue.status(unknownID)?.state) == "unconfirmed", "lost reply never replays")
        let blockedID = UUID().uuidString.lowercased()
        do { _ = try queue.enqueue(id: blockedID, selector: selector, value: payload(blockedID)); fatalError("uncertain overlapping request accepted") } catch {}
        now = 3000
        check(DeveloperInstallIntent.parse(value, bundleID: "dev.test.app", now: now) == nil, "expired at phone handoff")
        let cancelPath = root.appendingPathComponent("cancel.json")
        now = 1000
        let cancelled = try InstallRequestQueue(path: cancelPath, now: { now })
        _ = try cancelled.enqueue(id: id, selector: selector, value: value)
        _ = try cancelled.cancel(id)
        cancelled.inspect = { _ in .ready { fatalError("cancelled request sent") } }; cancelled.drain()
        check(try! cancelled.status(id)?.state == "cancelled", "cancel stays terminal")
        let expired = try InstallRequestQueue(path: root.appendingPathComponent("expired.json"), now: { now })
        _ = try expired.enqueue(id: id, selector: selector, value: value); now = 2001
        expired.inspect = { _ in .ready { fatalError("expired request sent") } }; expired.drain()
        check(try! expired.status(id)?.state == "expired", "expiry checked without timer")
        now = 1000
        let failed = try InstallRequestQueue(path: root.appendingPathComponent("failed.json"), now: { now })
        _ = try failed.enqueue(id: id, selector: selector, value: value)
        failed.inspect = { _ in .unsupported }; failed.drain()
        check(try! failed.status(id)?.state == "rejected", "old SDK gated")
        let brokenPath = root.appendingPathComponent("missing/queue.json")
        do { _ = try InstallRequestQueue(path: brokenPath); fatalError("missing private directory accepted") } catch {}
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        do { _ = try InstallRequestQueue(path: link); fatalError("symlink accepted") } catch {}
        let failRoot = root.appendingPathComponent("write-failure")
        try FileManager.default.createDirectory(at: failRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let failQueue = try InstallRequestQueue(path: failRoot.appendingPathComponent("queue.json"), now: { now })
        _ = try failQueue.enqueue(id: id, selector: selector, value: value)
        failQueue.inspect = { _ in
            try! FileManager.default.removeItem(at: failRoot)
            return .ready { fatalError("sent after durable fence failed") }
        }
        failQueue.drain()
        print("Install intent, foreground wait, durable restart, 32-way duplicate, lost reply, cancel, expiry, old SDK and failed-write checks passed")
    }
}
