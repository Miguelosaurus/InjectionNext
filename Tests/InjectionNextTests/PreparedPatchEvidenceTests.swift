import XCTest
import Darwin
@testable import InjectionBundle

final class PreparedPatchEvidenceTests: XCTestCase {
    /// Compile and load a real replacement using the current toolchain. A
    /// fabricated symbol list would miss the TI/TX ABI difference that caused
    /// a visible phone edit to be reported as having no applied replacement.
    func testCurrentCompilerReplacementProducesAppliedReceiptAfterVisibleEffect() throws {
        XCTAssertTrue(PreparedPatchEvidence.clientCapabilities.contains("replacement-proof-v2"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = root.appendingPathComponent("Baseline.swift")
        let patch = root.appendingPathComponent("Patch.swift")
        let baselineLibrary = root.appendingPathComponent("libSwiftSimReceiptFixture.dylib")
        let patchLibrary = root.appendingPathComponent("patch.dylib")
        try """
        public dynamic func receiptFixtureLabel() -> Int32 { 1 }
        @_cdecl("swiftSimReceiptFixtureLabel")
        public func readReceiptFixtureLabel() -> Int32 { receiptFixtureLabel() }
        """.write(to: baseline, atomically: true, encoding: .utf8)
        try """
        import SwiftSimReceiptFixture
        @_dynamicReplacement(for: receiptFixtureLabel())
        private func receiptFixtureReplacement() -> Int32 { 2 }
        """.write(to: patch, atomically: true, encoding: .utf8)
        try compile(["-emit-library", "-emit-module", "-module-name", "SwiftSimReceiptFixture",
                     baseline.path, "-o", baselineLibrary.path])
        try compile(["-emit-library", "-module-name", "SwiftSimReceiptReplacement", "-Xlinker", "-dead_strip", "-I", root.path,
                     "-L", root.path, "-lSwiftSimReceiptFixture", patch.path, "-o", patchLibrary.path])
        let baseHandle = try XCTUnwrap(dlopen(baselineLibrary.path, RTLD_NOW | RTLD_GLOBAL))
        let symbol = try XCTUnwrap(dlsym(baseHandle, "swiftSimReceiptFixtureLabel"))
        let visibleLabel = unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
        XCTAssertEqual(visibleLabel(), 1)
        let image = try XCTUnwrap(DLKit.load(dylib: patchLibrary.path))
        XCTAssertEqual(URL(fileURLWithPath: image.imagePath).resolvingSymlinksInPath(), patchLibrary.resolvingSymlinksInPath())
        XCTAssertEqual(visibleLabel(), 2, "The loaded library must actually replace the baseline function")
        XCTAssertEqual(image.swiftSymbols(withSuffixes: ["TI"]).count, 0,
                       "Regression fixture exercises the current ABI that the old report rejected")
        let replacements = PreparedPatchEvidence.dynamicReplacementCount(in: image)
        XCTAssertEqual(replacements, 1)

        let ledger = PreparedDeliveryLedger()
        let bytes = try Data(contentsOf: patchLibrary)
        let identity: [String: Any] = ["bundle_id": "fixture.receipt", "build_number": "1",
            "executable_uuid": "fixture-executable", "debug_dylib_uuid": "fixture-debug",
            "process_nonce": "fixture-process", "root_revision": 0, "root_ready": true, "is_active": true]
        let request: [String: Any] = ["request_id": UUID().uuidString,
            "patch_digest": PreparedDeliveryLedger.digest(bytes), "expires_at_ms": 2_000.0,
            "baseline_revision": 0, "attempt_id": "fixture-attempt", "expected_identity": identity]
        var report: [String: Any]?
        XCTAssertTrue(ledger.begin(request: request, data: bytes, identity: identity, now: 1_000) { report = $0 })
        ledger.finish(request: request, identity: identity, report: ["applied": replacements > 0,
            "dynamic_replacements": replacements, "refresh_acknowledged": true, "revision": 1])
        XCTAssertEqual(report?["applied"] as? Bool, true)
        XCTAssertEqual(report?["dynamic_replacements"] as? Int, 1)
        XCTAssertEqual(report?["root_revision"] as? Int, 1)

        let unstripped = root.appendingPathComponent("unstripped.dylib")
        try compile(["-emit-library", "-module-name", "SwiftSimReceiptUnstripped", "-I", root.path,
                     "-L", root.path, "-lSwiftSimReceiptFixture", patch.path, "-o", unstripped.path])
        let unstrippedImage = try XCTUnwrap(DLKit.load(dylib: unstripped.path))
        XCTAssertEqual(unstrippedImage.swiftSymbols(withSuffixes: ["TI"]).count, 1)
        XCTAssertEqual(unstrippedImage.swiftSymbols(withSuffixes: ["TX"]).count, 1)
        XCTAssertEqual(PreparedPatchEvidence.dynamicReplacementCount(in: unstrippedImage), 1,
                       "Two ABI variables for one replacement must not be counted twice")

        let plainSource = root.appendingPathComponent("Plain.swift")
        let plainLibrary = root.appendingPathComponent("plain.dylib")
        try "public func ordinaryFunction() -> Int32 { 3 }".write(to: plainSource, atomically: true, encoding: .utf8)
        try compile(["-emit-library", "-module-name", "SwiftSimReceiptPlain", plainSource.path, "-o", plainLibrary.path])
        let plainImage = try XCTUnwrap(DLKit.load(dylib: plainLibrary.path))
        XCTAssertEqual(PreparedPatchEvidence.dynamicReplacementCount(in: plainImage), 0,
                       "A loaded library without a replacement must still fail the applied-evidence check")
    }

    private func compile(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc"] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let diagnostics = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: diagnostics, as: UTF8.self))
        guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
    }
}
