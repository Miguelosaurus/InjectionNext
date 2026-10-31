#if DEBUG || !SWIFT_PACKAGE
import Foundation
import CryptoKit
import ObjectiveC
import Darwin
import MachO
#if canImport(InjectionNextC)
import InjectionNextC
#endif

/// Shared by the engine and Debug client. A missing contract is the legacy v2
/// path; malformed or unknown versions never silently downgrade.
struct PreparedReplacementProof {
    struct Callback {
        let className: String
        let selector: String
        let replacementSelector: String
        let typeEncoding: String
        var object: [String: Any] {
            ["class_name": className, "selector": selector,
             "replacement_selector": replacementSelector, "type_encoding": typeEncoding]
        }
        var key: String { className + "\u{0}" + selector }
        var replacementKey: String { className + "\u{0}" + replacementSelector }
    }
    let swiftReplacements: Int
    let callbacks: [Callback]
    var object: [String: Any] {
        ["version": 3, "swift_replacements": swiftReplacements, "objc_callbacks": callbacks.map { $0.object }]
    }
    var digest: String {
        let bytes = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    enum Failure: Error { case invalidContract, missingClass, inheritedOrMissingSelector, encodingMismatch, replacementAlreadyPresent, inspectionLimit }

    static func parse(_ value: Any?) throws -> PreparedReplacementProof? {
        guard let value else { return nil }
        guard let object = value as? [String: Any], Set(object.keys) == ["version", "swift_replacements", "objc_callbacks"],
              integer(object["version"]) == 3,
              let swiftCount = integer(object["swift_replacements"]), (0...512).contains(swiftCount),
              let callbacks = object["objc_callbacks"] as? [[String: Any]], callbacks.count <= 256,
              (1...512).contains(swiftCount + callbacks.count) else { throw Failure.invalidContract }
        var parsed: [Callback] = [], selectors = Set<String>()
        for item in callbacks {
            guard Set(item.keys) == ["class_name", "selector", "replacement_selector", "type_encoding"],
                  let name = item["class_name"] as? String, validName(name, max: 1024, extra: ".$"),
                  let selector = item["selector"] as? String, validSelector(selector),
                  let replacement = item["replacement_selector"] as? String, validSelector(replacement),
                  replacement != selector, selector.filter({ $0 == ":" }).count == replacement.filter({ $0 == ":" }).count,
                  let encoding = item["type_encoding"] as? String, !encoding.isEmpty, encoding.utf8.count <= 512,
                  encoding.utf8.allSatisfy({ (32...126).contains($0) }) else { throw Failure.invalidContract }
            let callback = Callback(className: name, selector: selector, replacementSelector: replacement, typeEncoding: encoding)
            guard selectors.insert(callback.key).inserted, selectors.insert(callback.replacementKey).inserted else { throw Failure.invalidContract }
            parsed.append(callback)
        }
        let result = PreparedReplacementProof(swiftReplacements: swiftCount, callbacks: parsed.sorted { $0.key < $1.key })
        guard let bytes = try? JSONSerialization.data(withJSONObject: result.object, options: [.sortedKeys, .withoutEscapingSlashes]),
              bytes.count <= 12_288 else { throw Failure.invalidContract }
        return result
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }
    private static func validName(_ value: String, max: Int, extra: String) -> Bool {
        guard let first = value.utf8.first, (65...90).contains(first) || (97...122).contains(first) || first == 95 || first == 36 else { return false }
        return value.utf8.count <= max && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || extra.utf8.contains($0)
        }
    }
    private static func validSelector(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        let body = value.hasSuffix(":") ? String(value.dropLast()) : value
        return body.split(separator: ":", omittingEmptySubsequences: false).allSatisfy { validName(String($0), max: 256, extra: "$") }
    }
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    struct Capture {
        let expectation: Callback
        let type: AnyClass
        let originalIMP: IMP
    }

    /// Call under the same serialized application gate as dlopen. Existing
    /// images remain loaded; this captures evidence, it never swizzles a method.
    func capture() throws -> [Capture] {
        try callbacks.map { callback in
            guard let type = NSClassFromString(callback.className),
                  String(cString: class_getName(type)) == callback.className else { throw Failure.missingClass }
            let selector = NSSelectorFromString(callback.selector)
            guard let method = Self.ownedMethod(type, selector) else { throw Failure.inheritedOrMissingSelector }
            guard let encoding = method_getTypeEncoding(method), String(cString: encoding) == callback.typeEncoding else { throw Failure.encodingMismatch }
            // Generated names identify a single artifact generation. Reusing an
            // existing selector could make a stale image satisfy a new request.
            guard class_getInstanceMethod(type, NSSelectorFromString(callback.replacementSelector)) == nil else {
                throw Failure.replacementAlreadyPresent
            }
            return Capture(expectation: callback, type: type, originalIMP: method_getImplementation(method))
        }
    }

    func evaluate(captures: [Capture], imagePath: String, swiftCount: Int) -> [String: Any] {
        let expectedPath = URL(fileURLWithPath: imagePath).standardizedFileURL.resolvingSymlinksInPath().path
        var proofs: [[String: Any]] = []
        var validKeys = Set<String>()
        for capture in captures {
            let callback = capture.expectation
            let target = Self.ownedMethod(capture.type, NSSelectorFromString(callback.selector))
            let replacement = Self.ownedMethod(capture.type, NSSelectorFromString(callback.replacementSelector))
            var matched = false, changed = false, imageMatches = false, encodingMatches = false
            if let target, let replacement {
                let targetIMP = method_getImplementation(target), replacementIMP = method_getImplementation(replacement)
                matched = Self.address(targetIMP) == Self.address(replacementIMP)
                changed = Self.address(targetIMP) != Self.address(capture.originalIMP)
                if let targetEncoding = method_getTypeEncoding(target), let replacementEncoding = method_getTypeEncoding(replacement) {
                    encodingMatches = String(cString: targetEncoding) == callback.typeEncoding
                        && String(cString: replacementEncoding) == callback.typeEncoding
                }
                imageMatches = Self.imagePath(targetIMP) == expectedPath && Self.imagePath(replacementIMP) == expectedPath
            }
            let verified = matched && changed && imageMatches && encodingMatches
            if verified { validKeys.insert(callback.key); validKeys.insert(callback.replacementKey) }
            var proof = callback.object
            proof["verified"] = verified
            proof["owns_selector"] = target != nil && replacement != nil
            proof["implementation_matches"] = matched
            proof["previous_implementation_changed"] = changed
            proof["implementation_in_patch"] = imageMatches
            proof["encoding_matches"] = encodingMatches
            proofs.append(proof)
        }
        let actual = try? Self.methodsOwned(byImage: expectedPath)
        let complete = swiftCount == swiftReplacements && captures.count == callbacks.count
            && proofs.count == callbacks.count && validKeys.count == callbacks.count * 2
            && actual == validKeys
        let objcCount = proofs.filter { $0["verified"] as? Bool == true }.count
        return ["replacement_proof_version": 3, "coverage_digest": digest,
                "expected_swift_replacements": swiftReplacements, "dynamic_replacements": swiftCount,
                "objc_replacements": objcCount, "objc_callback_proofs": proofs,
                "represented_replacements": swiftCount + objcCount,
                "complete_replacement_coverage": complete]
    }

    func validatesSuccessfulReport(_ report: [String: Any]) -> Bool {
        guard Self.integer(report["replacement_proof_version"]) == 3,
              report["coverage_digest"] as? String == digest,
              Self.boolean(report["complete_replacement_coverage"]) == true,
              Self.integer(report["dynamic_replacements"]) == swiftReplacements,
              Self.integer(report["expected_swift_replacements"]) == swiftReplacements,
              Self.integer(report["objc_replacements"]) == callbacks.count,
              Self.integer(report["represented_replacements"]) == swiftReplacements + callbacks.count,
              let proofs = report["objc_callback_proofs"] as? [[String: Any]], proofs.count == callbacks.count else { return false }
        for (callback, proof) in zip(callbacks, proofs) {
            guard callback.object.allSatisfy({ proof[$0.key] as? String == $0.value as? String }),
                  ["owns_selector", "implementation_matches", "encoding_matches", "implementation_in_patch", "previous_implementation_changed", "verified"]
                    .allSatisfy({ Self.boolean(proof[$0]) == true }) else { return false }
        }
        return true
    }

    private static func ownedMethod(_ type: AnyClass, _ selector: Selector) -> Method? {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(type, &count) else { return nil }
        defer { free(methods) }
        guard count <= 16_384 else { return nil }
        for index in 0..<Int(count) where method_getName(methods[index]) == selector { return class_getInstanceMethod(type, selector) }
        return nil
    }
    private static func address(_ imp: IMP) -> UInt { SwiftSimPreparedIMPAddress(imp) }
    private static func imagePath(_ imp: IMP) -> String? {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address(imp)), &info) != 0, let path = info.dli_fname else { return nil }
        return URL(fileURLWithPath: String(cString: path)).standardizedFileURL.resolvingSymlinksInPath().path
    }
    private static func methodsOwned(byImage path: String) throws -> Set<String> {
        var imageBase: UnsafeRawPointer?
        var executableRanges: [Range<UInt>] = []
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            let candidate = URL(fileURLWithPath: String(cString: name)).standardizedFileURL.resolvingSymlinksInPath().path
            if candidate == path, let header = _dyld_get_image_header(index) {
                imageBase = UnsafeRawPointer(header)
                executableRanges = try codeRanges(header: header, slide: _dyld_get_image_vmaddr_slide(index))
                break
            }
        }
        guard let imageBase else { throw Failure.inspectionLimit }
        var count: UInt32 = 0
        guard let classes = objc_copyClassList(&count) else { throw Failure.inspectionLimit }
        defer { free(UnsafeMutableRawPointer(classes)) }
        guard count <= 100_000 else { throw Failure.inspectionLimit }
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "object_getClass") else { throw Failure.inspectionLimit }
        let rawObjectGetClass = unsafeBitCast(symbol, to: (@convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?).self)
        var output = Set<String>()
        var inspectedMethods = 0
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        for index in 0..<Int(count) {
            // The imported autoreleasing Class array subscript performs a Swift
            // dynamic cast, which sends +class to runtime-only root classes
            // (e.g. __NSGenericDeallocHandler) and can abort. Class pointers
            // from this runtime API are already typed; read their raw storage.
            guard DispatchTime.now().uptimeNanoseconds <= deadline else { throw Failure.inspectionLimit }
            let pointer = UnsafeRawPointer(classes).assumingMemoryBound(to: UnsafeRawPointer.self)[index]
            let type: AnyClass = unsafeBitCast(pointer, to: AnyClass.self)
            // object_getClass's Swift Any bridge retains/releases a class
            // object; runtime-only roots need not implement NSObject ownership.
            // Use the C pointer ABI directly, without sending any messages.
            guard let metaPointer = rawObjectGetClass(pointer) else { throw Failure.inspectionLimit }
            let metaclass: AnyClass = unsafeBitCast(metaPointer, to: AnyClass.self)
            let inspections: [(AnyClass, Bool)] = [(type, false), (metaclass, true)]
            for inspection in inspections {
                let inspected: AnyClass = inspection.0
                let isMeta = inspection.1
                var methodCount: UInt32 = 0
                guard let methods = class_copyMethodList(inspected, &methodCount) else { continue }
                defer { free(methods) }
                guard methodCount <= 16_384 else { throw Failure.inspectionLimit }
                inspectedMethods += Int(methodCount)
                guard inspectedMethods <= 2_000_000 else { throw Failure.inspectionLimit }
                for methodIndex in 0..<Int(methodCount) {
                    let method = methods[methodIndex]
                    let implementationAddress = address(method_getImplementation(method))
                    guard let implementation = UnsafeRawPointer(bitPattern: implementationAddress) else { continue }
                    // Most methods belong to the OS. dladdr symbol lookup for
                    // every OS IMP can take seconds; mapped executable ranges
                    // cheaply exclude them before exact image-base validation.
                    guard executableRanges.contains(where: { $0.contains(implementationAddress) }) else { continue }
                    var info = Dl_info()
                    if dladdr(implementation, &info) != 0,
                       info.dli_fbase == imageBase {
                        guard !isMeta else { throw Failure.inspectionLimit }
                        output.insert(String(cString: class_getName(type)) + "\u{0}" + NSStringFromSelector(method_getName(method)))
                    }
                }
            }
        }
        return output
    }
    private static func codeRanges(header: UnsafePointer<mach_header>, slide: Int) throws -> [Range<UInt>] {
        guard header.pointee.magic == MH_MAGIC_64 else { throw Failure.inspectionLimit }
        let raw = UnsafeRawPointer(header)
        let value = raw.load(as: mach_header_64.self)
        guard value.ncmds <= 4_096, value.sizeofcmds <= 1_048_576 else { throw Failure.inspectionLimit }
        var offset = MemoryLayout<mach_header_64>.size
        let end = offset + Int(value.sizeofcmds)
        var ranges: [Range<UInt>] = []
        for _ in 0..<value.ncmds {
            guard offset + MemoryLayout<load_command>.size <= end else { throw Failure.inspectionLimit }
            let command = raw.load(fromByteOffset: offset, as: load_command.self)
            guard command.cmdsize >= MemoryLayout<load_command>.size,
                  offset + Int(command.cmdsize) <= end else { throw Failure.inspectionLimit }
            if command.cmd == LC_SEGMENT_64 {
                guard command.cmdsize >= MemoryLayout<segment_command_64>.size else { throw Failure.inspectionLimit }
                let segment = raw.load(fromByteOffset: offset, as: segment_command_64.self)
                if segment.initprot & VM_PROT_EXECUTE != 0 {
                    let start = UInt(segment.vmaddr) &+ UInt(bitPattern: slide)
                    let (finish, overflow) = start.addingReportingOverflow(UInt(segment.vmsize))
                    guard !overflow, finish > start else { throw Failure.inspectionLimit }
                    ranges.append(start..<finish)
                }
            }
            offset += Int(command.cmdsize)
        }
        guard !ranges.isEmpty else { throw Failure.inspectionLimit }
        return ranges
    }

}
#endif
