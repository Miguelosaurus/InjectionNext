import XCTest
import Darwin
import ObjectiveC
@testable import InjectionBundle

final class PreparedReplacementProofTests: XCTestCase {
    private func contract(_ callbacks: [[String: Any]] = [], swift: Int = 1) -> [String: Any] {
        ["version": 3, "swift_replacements": swift, "objc_callbacks": callbacks]
    }
    private var vectorCallback: [String: Any] {
        ["class_name": "_TtC7Example11Coordinator", "selector": "scrollViewWillBeginDragging:",
         "replacement_selector": "__swiftSim_callback:", "type_encoding": "v24@0:8@16"]
    }
    func testCanonicalVectorAndStrictContractBounds() throws {
        let proof = try XCTUnwrap(PreparedReplacementProof.parse(contract([vectorCallback], swift: 6)))
        XCTAssertEqual(proof.digest, "a375fa459679b23c12fba308dc177f66bad83f9de4478d63fb248e431cbfafd5")
        XCTAssertNil(try PreparedReplacementProof.parse(nil), "v2 remains optional")
        var badValues: [[String: Any]] = []
        for (key, value) in [("version", true as Any), ("swift_replacements", true), ("swift_replacements", -1), ("swift_replacements", 513), ("version", 4), ("version", 3.5)] {
            var bad = contract(); bad[key] = value; badValues.append(bad)
        }
        var unknown = contract(); unknown["unknown"] = 1; badValues.append(unknown)
        badValues.append(contract([], swift: 0))
        badValues.append(contract([vectorCallback, vectorCallback]))
        for (key, value) in [("class_name", "1Bad"), ("selector", "x::"), ("replacement_selector", "wrongArity"), ("type_encoding", "v\n"), ("selector", String(repeating: "x", count: 256) + ":")] {
            var bad = vectorCallback; bad[key] = value; badValues.append(contract([bad]))
        }
        var overlap = vectorCallback; overlap["selector"] = vectorCallback["replacement_selector"]; overlap["replacement_selector"] = "other:"
        badValues.append(contract([vectorCallback, overlap]))
        let huge = (0..<40).map { n -> [String: Any] in
            var callback = vectorCallback; callback["class_name"] = "Class\(n)" + String(repeating: "x", count: 400); return callback
        }
        badValues.append(contract(huge))
        for value in badValues { XCTAssertThrowsError(try PreparedReplacementProof.parse(value)) }
    }

    func testStrictReceiptScalarsAndExactCoverage() throws {
        let proof = try XCTUnwrap(PreparedReplacementProof.parse(contract([vectorCallback])))
        var callback = vectorCallback
        for key in ["owns_selector", "implementation_matches", "encoding_matches", "implementation_in_patch", "previous_implementation_changed", "verified"] { callback[key] = true }
        let good: [String: Any] = ["replacement_proof_version": 3, "coverage_digest": proof.digest,
            "expected_swift_replacements": 1, "dynamic_replacements": 1, "objc_replacements": 1,
            "represented_replacements": 2, "complete_replacement_coverage": true, "objc_callback_proofs": [callback]]
        XCTAssertTrue(proof.validatesSuccessfulReport(good))
        for key in ["expected_swift_replacements", "dynamic_replacements", "objc_replacements", "represented_replacements", "replacement_proof_version"] {
            var bad = good; bad[key] = true; XCTAssertFalse(proof.validatesSuccessfulReport(bad))
        }
        for (key, value) in [("coverage_digest", "wrong" as Any), ("complete_replacement_coverage", 1), ("objc_callback_proofs", []), ("objc_callback_proofs", [callback, callback])] {
            var bad = good; bad[key] = value; XCTAssertFalse(proof.validatesSuccessfulReport(bad))
        }
        for key in ["owns_selector", "implementation_matches", "encoding_matches", "implementation_in_patch", "previous_implementation_changed", "verified"] {
            var badCallback = callback; badCallback[key] = 1
            var bad = good; bad["objc_callback_proofs"] = [badCallback]; XCTAssertFalse(proof.validatesSuccessfulReport(bad))
        }
    }

    /// Actual compiler-emitted ObjC categories on a private nested Swift class.
    /// No fake runtime tables: dlopen updates dispatch on an existing object.
    func testRealNestedCallbackGenerationsAndExtraMethodRejection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = root.appendingPathComponent("Baseline.swift")
        try """
        import Foundation
        @objc public protocol ReceiptCallbackDelegate { func callback(_ value: NSNumber) -> NSNumber }
        public enum ReceiptOuter {
            private final class Coordinator: NSObject, ReceiptCallbackDelegate {
                func callback(_ value: NSNumber) -> NSNumber { NSNumber(value: value.intValue + 1) }
            }
            public static func make() -> NSObject { Coordinator() }
        }
        @_cdecl("receiptCallbackCreate") public func create() -> UnsafeMutableRawPointer {
            Unmanaged.passRetained(ReceiptOuter.make()).toOpaque()
        }
        public dynamic func swiftValue() -> Int { 1 }
        """.write(to: baseline, atomically: true, encoding: .utf8)
        let baseLibrary = root.appendingPathComponent("libReceiptCallbackBaseline.dylib")
        try compile(["-emit-library", "-emit-module", "-module-name", "ReceiptCallbackBaseline", "-enable-private-imports",
                     "-Xfrontend", "-enable-implicit-dynamic", baseline.path, "-o", baseLibrary.path])
        let handle = try XCTUnwrap(dlopen(baseLibrary.path, RTLD_NOW | RTLD_GLOBAL))
        let factory = unsafeBitCast(try XCTUnwrap(dlsym(handle, "receiptCallbackCreate")), to: (@convention(c) () -> UnsafeMutableRawPointer).self)
        let object = Unmanaged<NSObject>.fromOpaque(factory()).takeRetainedValue()
        let className = String(cString: class_getName(type(of: object)))
        XCTAssertTrue(className.contains("Coordinator"))
        let selector = NSSelectorFromString("callback:")
        let encoding = String(cString: method_getTypeEncoding(try XCTUnwrap(class_getInstanceMethod(type(of: object), selector)))!)
        func callback(_ alias: String) -> [String: Any] {
            ["class_name": className, "selector": "callback:", "replacement_selector": alias, "type_encoding": encoding]
        }
        func call() -> Int { (object.perform(selector, with: NSNumber(value: 7)).takeUnretainedValue() as! NSNumber).intValue }
        XCTAssertEqual(call(), 8)
        for (key, value) in [("class_name", "MissingCallbackClass"), ("selector", "description"), ("selector", "missing:"), ("type_encoding", "v24@0:8@16")] {
            var item = callback("patch_1:"); item[key] = value
            if value == "description" { item["replacement_selector"] = "replacementDescription" }
            let proof = try XCTUnwrap(PreparedReplacementProof.parse(contract([item], swift: 0)))
            XCTAssertThrowsError(try proof.capture(), "\(key)=\(value) must fail before load")
        }
        for generation in 1...5 {
            let offset = generation == 5 ? 1 : generation * 100
            let alias = "patch_\(generation):"
            let swiftCount = generation == 1 ? 0 : 1
            let proof = try XCTUnwrap(PreparedReplacementProof.parse(contract([callback(alias)], swift: swiftCount)))
            let captures = try proof.capture()
            let patch = root.appendingPathComponent("Patch\(generation).swift")
            var source = """
            @_private(sourceFile: "Baseline.swift") import ReceiptCallbackBaseline
            import Foundation
            extension ReceiptOuter.Coordinator {
                @_dynamicReplacement(for: callback(_:))
                private func patch_\(generation)(_ value: NSNumber) -> NSNumber { NSNumber(value: value.intValue + \(offset)) }
            """
            if generation == 3 { source += "\n @objc func unapprovedExtra() -> Int { 3 }\n" }
            if generation == 4 { source += "\n @objc class func unapprovedClassExtra() -> Int { 4 }\n" }
            source += "\n}\n"
            if swiftCount == 1 { source += "@_dynamicReplacement(for: swiftValue()) private func newSwiftValue() -> Int { \(generation) }\n" }
            try source.write(to: patch, atomically: true, encoding: .utf8)
            let library = root.appendingPathComponent("patch\(generation).dylib")
            try compile(["-emit-library", "-module-name", "ReceiptCallbackPatch\(generation)", "-I", root.path, "-L", root.path,
                         "-lReceiptCallbackBaseline", "-Xfrontend", "-disable-access-control", patch.path, "-o", library.path])
            let image = try XCTUnwrap(DLKit.load(dylib: library.path))
            XCTAssertEqual(call(), offset + 7, "existing object dispatch must actually change")
            let actualSwift = PreparedPatchEvidence.dynamicReplacementCount(in: image)
            XCTAssertEqual(actualSwift, swiftCount, "ObjC category is never counted as a Swift TX")
            let receipt = proof.evaluate(captures: captures, imagePath: image.imagePath, swiftCount: actualSwift)
            XCTAssertEqual(receipt["complete_replacement_coverage"] as? Bool, (generation <= 2 || generation == 5))
            XCTAssertEqual(proof.validatesSuccessfulReport(receipt), (generation <= 2 || generation == 5))
            XCTAssertFalse(proof.evaluate(captures: captures, imagePath: baseLibrary.path, swiftCount: swiftCount)["complete_replacement_coverage"] as! Bool, "wrong loaded image cannot prove ownership")
            XCTAssertFalse(proof.evaluate(captures: captures, imagePath: image.imagePath, swiftCount: swiftCount + 1)["complete_replacement_coverage"] as! Bool)
            XCTAssertFalse(proof.evaluate(captures: [], imagePath: image.imagePath, swiftCount: swiftCount)["complete_replacement_coverage"] as! Bool)
            XCTAssertThrowsError(try proof.capture(), "a loaded alias is stale for another application")
        }
    }

    private func compile(_ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc"] + arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); let diagnostics = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: diagnostics, as: UTF8.self))
        guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
    }
}
