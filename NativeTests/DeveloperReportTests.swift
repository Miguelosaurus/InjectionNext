import AppKit

@main
struct DeveloperReportTests {
    static func require(_ condition: Bool, _ reason: String) {
        if !condition { fatalError(reason) }
    }
    static func rejected(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected refusal") } catch {}
    }
    static func main() throws {
        let parent = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = DeveloperReportStore(root: parent.appendingPathComponent("reports"), clock: { now })
        let identity: [String: Any] = ["bundle_id": "example.fixture", "bundle_version": "1.0", "build_number": "36",
            "executable_uuid": UUID().uuidString.lowercased(), "debug_dylib_uuid": UUID().uuidString.lowercased(),
            "process_nonce": UUID().uuidString.lowercased(), "connection_nonce": UUID().uuidString.lowercased(),
            "is_active": true, "root_ready": true, "root_revision": 4]
        func metadata() -> [String: Any] { ["schema_version": 1, "report_id": UUID().uuidString.lowercased(), "note": "Reproduce tap", "revision": 3] }
        require(DeveloperReportStore.matches(identity, selector: identity), "exact binary accepted")
        var wrong = identity; wrong["executable_uuid"] = UUID().uuidString
        require(!DeveloperReportStore.matches(identity, selector: wrong), "other binary refused")
        require(!DeveloperReportStore.matches(identity, selector: [:]), "unscoped selector refused")
        rejected { _ = try store.latest(selector: identity) }
        require(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("reports").path), "read does not initialize store")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.setColor(.red, atX: 0, y: 0)
        let jpeg = bitmap.representation(using: .jpeg, properties: [:])!
        require(DeveloperReportStore.validJPEG(jpeg), "real bounded JPEG accepted")
        require(!DeveloperReportStore.validJPEG(Data([0xff, 0xd8, 0xff])), "JPEG header alone refused")
        var first = metadata(); first["token"] = "must-not-be-persisted"
        let result = try store.save(metadata: first, image: jpeg, identity: identity)
        let id = result["report_id"] as! String
        require((result["metadata"] as? [String: Any])?["token"] == nil, "diagnostics allowlist excludes unknown secrets")
        require((result["metadata"] as? [String: Any])?["revision"] as? Int == 3, "capture revision remains distinct from submitted connection revision")
        let read = try store.latest(selector: identity)
        require(read["report_id"] as? String == id, "latest report retrieved by exact binary")
        require((read["screenshot"] as? [String: Any])?["bytes"] as? Int == jpeg.count, "image persisted with bounded length")
        let duplicate = try store.save(metadata: first, image: jpeg, identity: identity)
        require(duplicate["created_at"] as? String == result["created_at"] as? String, "identical retry is idempotent")
        rejected { _ = try store.latest(selector: wrong, reportID: id) }
        var changed = first; changed["note"] = "different"
        rejected { _ = try store.save(metadata: changed, image: jpeg, identity: identity) }
        rejected { _ = try store.save(metadata: metadata(), image: Data(repeating: 0, count: 1_048_577), identity: identity) }
        var huge = metadata(); huge["note"] = String(repeating: "x", count: 2_049)
        rejected { _ = try store.save(metadata: huge, image: jpeg, identity: identity) }
        let path = parent.appendingPathComponent("reports/" + id + ".json")
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        require((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "report is owner-only")
        for _ in 0..<5 { now.addTimeInterval(1); _ = try store.save(metadata: metadata(), image: Data(), identity: identity) }
        require(try FileManager.default.contentsOfDirectory(atPath: parent.appendingPathComponent("reports").path).count == 5, "five-report retention")
        rejected { _ = try store.latest(selector: identity, reportID: id) }
        now.addTimeInterval(86_401)
        rejected { _ = try store.latest(selector: identity) }
        require(try FileManager.default.contentsOfDirectory(atPath: parent.appendingPathComponent("reports").path).isEmpty, "expired artifacts removed opportunistically")
        let latest = try store.save(metadata: metadata(), image: Data(), identity: identity)
        let latestPath = parent.appendingPathComponent("reports/" + (latest["report_id"] as! String) + ".json")
        try FileManager.default.removeItem(at: latestPath)
        let foreign = parent.appendingPathComponent("foreign.json")
        try Data("private".utf8).write(to: foreign)
        try FileManager.default.createSymbolicLink(at: latestPath, withDestinationURL: foreign)
        rejected { _ = try store.latest(selector: identity) }
        require(try Data(contentsOf: foreign) == Data("private".utf8), "symlink target never followed or deleted")
        print("Developer report bounds, identity, idempotency and private retention checks passed")
    }
}
