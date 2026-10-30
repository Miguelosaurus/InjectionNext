import XCTest
import Darwin
@testable import InjectionBundle

final class LocalDeclarationReplacementEvidenceTests: XCTestCase {
    /// Real compiler/load/application evidence for locals in existing methods.
    /// This is a native host test, not an iPhone root-refresh receipt.
    func testLocalBindingsReplaceMethodsOnAnExistingInstance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = root.appendingPathComponent("Baseline.swift")
        let patch = root.appendingPathComponent("Patch.swift")
        let library = root.appendingPathComponent("libSwiftSimLocalDeclarationFixture.dylib")
        let replacement = root.appendingPathComponent("replacement.dylib")
        let cases = [
            ("constant", "let local: Int32 = 2; return local", Int32(2)),
            ("mutable", "var local: Int32 = 1; local += 2; return local", Int32(3)),
            ("guardBinding", "let candidate: Int32? = 4; guard let local = candidate else { return 0 }; return local", Int32(4)),
            ("ifBinding", "let candidate: Int32? = 5; if let local = candidate { return local }; return 0", Int32(5)),
            ("caseBinding", "let candidate: Int32? = 6; switch candidate { case .some(let local): return local; case .none: return 0 }", Int32(6)),
            ("closureBinding", "let operation: (Int32) -> Int32 = { input in let local = input + 1; return local }; return operation(6)", Int32(7)),
        ]
        let methods = cases.map { "public dynamic func \($0.0)() -> Int32 { 1 }" }.joined(separator: "\n")
        let branches = cases.enumerated().map { "case \($0.offset): return existingLocalProbe.\($0.element.0)()" }.joined(separator: "\n")
        try """
        public final class LocalDeclarationProbe {
            public init() {}
            \(methods)
        }
        private let existingLocalProbe = LocalDeclarationProbe()
        @_cdecl("swiftSimReadLocalDeclarationProbe")
        public func readLocalDeclarationProbe(_ index: Int32) -> Int32 {
            switch index {
            \(branches)
            default: return -1
            }
        }
        """.write(to: baseline, atomically: true, encoding: .utf8)
        let methodsAfter = cases.map {
            "@_dynamicReplacement(for: \($0.0)()) private func replacement_\($0.0)() -> Int32 { \($0.1) }"
        }.joined(separator: "\n")
        try """
        import SwiftSimLocalDeclarationFixture
        extension LocalDeclarationProbe {
            \(methodsAfter)
        }
        """.write(to: patch, atomically: true, encoding: .utf8)
        try compile(["-emit-library", "-emit-module", "-module-name", "SwiftSimLocalDeclarationFixture",
                     baseline.path, "-o", library.path])
        try compile(["-emit-library", "-module-name", "SwiftSimLocalDeclarationReplacement",
                     "-Xlinker", "-dead_strip", "-I", root.path, "-L", root.path,
                     "-lSwiftSimLocalDeclarationFixture", patch.path, "-o", replacement.path])
        let handle = try XCTUnwrap(dlopen(library.path, RTLD_NOW | RTLD_GLOBAL))
        let symbol = try XCTUnwrap(dlsym(handle, "swiftSimReadLocalDeclarationProbe"))
        let read = unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Int32).self)
        for index in cases.indices { XCTAssertEqual(read(Int32(index)), 1) }
        let image = try XCTUnwrap(DLKit.load(dylib: replacement.path))
        XCTAssertEqual(URL(fileURLWithPath: image.imagePath).resolvingSymlinksInPath(), replacement.resolvingSymlinksInPath())
        XCTAssertEqual(PreparedPatchEvidence.dynamicReplacementCount(in: image), cases.count)
        for (index, item) in cases.enumerated() {
            XCTAssertEqual(read(Int32(index)), item.2, "Existing instance must execute the \(item.0) replacement")
        }
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
