//
//  InjectionNext.swift
//  InjectionNext Package
//
//  Created by John Holdsworth on 30/05/2024.
//
//  Client app side of injection using implementation of InjectionLite.
//
#if DEBUG || !SWIFT_PACKAGE
import Foundation
import Network
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if canImport(InjectionImpl)
import InjectionImpl
#endif
#if canImport(InjectionNextC)
@_exported import InjectionNextC
#endif

@objc(InjectionNext)
open class InjectionNext: SimpleSocket {
    private let responseQueue = DispatchQueue(label: "InjectionNextResponses")
    private static var tracingInitialized = false // Reloader.injectionQueue only
    private static let applyGate = DispatchSemaphore(value: 1)
    private let connectionNonce = UUID().uuidString.lowercased()
    private static let processNonce = UUID().uuidString.lowercased()
    private var preparedDeliveryNegotiated = false // responseQueue only
    private let developerLock = NSLock()
    private var developerReady = false
    private var developerSending = false
    private static let networkRecovery: Void = {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "SwiftSimNetworkRecovery")
        var observedInitialPath = false
        monitor.pathUpdateHandler = { _ in
            // A route can change while interface names and status stay equal
            // (for example Wi-Fi roaming). Every subsequent path update wakes
            // the one owner; the initial observation never tears down startup.
            if observedInitialPath { InjectionWakeConnection() }
            observedInitialPath = true
        }
        monitor.start(queue: queue)
        networkMonitor = monitor
    }()
    private static var networkMonitor: NWPathMonitor?

    private func clientIdentity() -> [String: Any] {
        var identity = InjectionClientExecutionState() as? [String: Any] ?? [:]
        identity["bundle_id"] = Bundle.main.bundleIdentifier ?? ""
        identity["bundle_version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        identity["build_number"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        identity["executable_uuid"] = InjectionImageUUID(false)
        identity["debug_dylib_uuid"] = InjectionImageUUID(true)
        identity["process_nonce"] = Self.processNonce
        identity["connection_nonce"] = connectionNonce
        return identity
    }

    private func sendClientIdentity(negotiate: Bool = false) {
        responseQueue.async {
            if negotiate { self.preparedDeliveryNegotiated = true }
            guard self.preparedDeliveryNegotiated else { return }
            let payload: [String: Any] = ["protocol": 1, "identity": self.clientIdentity(),
                "capabilities": PreparedPatchEvidence.clientCapabilities]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            _ = self.writeCommand(InjectionResponse.swiftSimClient.rawValue, with: json)
        }
    }

    private func sendPreparedReport(_ report: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: report),
              let json = String(data: data, encoding: .utf8) else { return }
        sendResponse(.patchResult, with: json)
    }

    /// Admission is not a save receipt. The Mac acknowledges only after persistence.
    @objc(submitDeveloperReport:image:)
    func submitDeveloperReport(_ metadata: [String: Any], image: Data) -> Bool {
        guard let id = metadata["report_id"] as? String, UUID(uuidString: id) != nil,
              metadata["schema_version"] as? Int == 1,
              image.count <= 1_048_576,
              image.isEmpty || image.starts(with: [0xff, 0xd8, 0xff]),
              let encoded = try? JSONSerialization.data(withJSONObject: metadata), encoded.count <= 16_384,
              !PreparedDeliveryLedger.shared.hasPending else { return false }
        developerLock.lock()
        guard developerReady && !developerSending else { developerLock.unlock(); return false }
        developerSending = true
        developerLock.unlock()
        let envelope: [String: Any] = ["metadata": metadata, "identity": clientIdentity()]
        guard let bytes = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: bytes, encoding: .utf8) else {
            developerLock.lock(); developerSending = false; developerLock.unlock(); return false
        }
        responseQueue.async {
            defer { self.developerLock.lock(); self.developerSending = false; self.developerLock.unlock() }
            guard !PreparedDeliveryLedger.shared.hasPending else {
                self.developerResult(id: id, saved: false, error: "DEVELOPER_BUSY"); return
            }
            guard self.writePrepared(command: InjectionResponse.developerReport.rawValue,
                metadata: json, data: image, timeout: 0.3) else {
                self.developerResult(id: id, saved: false, error: "DEVELOPER_REPORT_UNAVAILABLE"); return
            }
        }
        return true
    }

    private func developerResult(id: String, saved: Bool, error: String? = nil) {
        var info: [String: Any] = ["report_id": id, "saved": saved]
        if let error { info["error"] = error }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("SWIFT_SIM_DEVELOPER_REPORT_RESULT"), object: nil, userInfo: info)
        }
    }

    private func developerScreenshot(_ request: [String: Any]) {
        guard let captureID = request["capture_id"] as? String, UUID(uuidString: captureID) != nil else { return }
        let identity = clientIdentity()
        var result: [String: Any] = ["capture_id": captureID, "identity": identity]
        var image: Data?
        let expected = request["expected_identity"] as? [String: Any] ?? [:]
        guard ["bundle_id", "executable_uuid", "debug_dylib_uuid", "process_nonce", "connection_nonce"].allSatisfy({
            expected[$0] as? String == identity[$0] as? String && expected[$0] is String
        }) else {
            result["error"] = "DEVELOPER_IDENTITY_MISMATCH"
            sendDeveloperScreenshot(result, image: nil); return
        }
        if PreparedDeliveryLedger.shared.hasPending { result["error"] = "DEVELOPER_BUSY" }
        else if identity["is_active"] as? Bool != true { result["error"] = "DEVELOPER_NOT_FOREGROUND" }
        else {
            image = boundedDeveloperScreenshot()
            if image == nil { result["error"] = "DEVELOPER_CAPTURE_UNAVAILABLE" }
        }
        sendDeveloperScreenshot(result, image: image)
    }

    private func sendDeveloperScreenshot(_ metadata: [String: Any], image: Data?) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: metadata),
              let json = String(data: bytes, encoding: .utf8) else { return }
        responseQueue.async {
            _ = self.writePrepared(command: InjectionResponse.developerScreenshotData.rawValue,
                metadata: json, data: image ?? Data(), timeout: 0.3)
        }
    }

    /// Capture only an unambiguous foreground scene; no global first-window guess.
    /// The hierarchy draw is on main, compression runs on the existing reader.
    private func boundedDeveloperScreenshot() -> Data? {
        #if canImport(UIKit) && !os(watchOS)
        var image: UIImage?
        let capture = {
            guard UIApplication.shared.applicationState == .active else { return }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }
            guard scenes.count == 1 else { return }
            let windows = scenes[0].windows.filter { !$0.isHidden && $0.alpha > 0 && $0.windowLevel == .normal }
            let candidates = windows.filter { $0.isKeyWindow }
            guard let window = candidates.count == 1 ? candidates.first : (windows.count == 1 ? windows.first : nil),
                  window.bounds.width > 0, window.bounds.height > 0 else { return }
            let format = UIGraphicsImageRendererFormat()
            format.scale = min(window.screen.scale, sqrt(1_950_000 / (window.bounds.width * window.bounds.height)))
            format.preferredRange = .standard
            var complete = false
            let rendered = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
                complete = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            if complete { image = rendered }
        }
        Thread.isMainThread ? capture() : DispatchQueue.main.sync(execute: capture)
        guard let image else { return nil }
        for quality in [CGFloat(0.8), 0.6, 0.4] {
            if let bytes = image.jpegData(compressionQuality: quality), bytes.count <= 1_048_576 { return bytes }
        }
        #endif
        return nil
    }

    private func sendResponse(_ response: InjectionResponse,
                              with string: String? = nil,
                              data: Data? = nil,
                              extra: (() -> Void)? = nil) {
        responseQueue.async {
            _ = self.writeCommand(response.rawValue, with: string)
            if let data = data {
                self.write(data)
            }
            extra?()
        }
    }

    override class open func error(_ message: String) -> Int32 {
        let msg = String(format: message, strerror(errno))
        print(APP_PREFIX+APP_NAME+": "+msg)
        if errno == EHOSTUNREACH { // No route to host
            print("ℹ️ "+APP_NAME+": Accept permission prompt on device.")
        }
        return errno
    }

    func log(_ msg: String) {
        print(APP_PREFIX+APP_NAME+": "+msg)
    }
    func error(_ msg: String) {
        log("⚠️ "+msg)
    }

    private func screenshotData() -> Data? {
        var data: Data?
        let capture = {
            #if canImport(UIKit) && !os(watchOS)
            guard let window = UIApplication.shared.windows.first(where: {
                $0.isKeyWindow
            }) ?? UIApplication.shared.windows.first(where: {
                !$0.isHidden && $0.alpha > 0
            }) else { return }
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            data = renderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }.pngData()
            #elseif canImport(AppKit)
            guard let window = NSApplication.shared.keyWindow ??
                    NSApplication.shared.mainWindow ??
                    NSApplication.shared.windows.first(where: {
                        $0.isVisible
                    }) else { return }
            window.displayIfNeeded()
            let bounds = window.contentView?.bounds ?? window.frame
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
                return
            }
            view.cacheDisplay(in: bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
            #endif
        }
        Thread.isMainThread ? capture() : DispatchQueue.main.sync(execute: capture)
        return data
    }

    /// Connection from client app opened in ClientBoot.mm arrives here
    open override func runInBackground() {
        defer {
            developerLock.lock(); developerReady = false; developerLock.unlock()
            disconnect()
        }
        super.write(INJECTION_VERSION)
        #if targetEnvironment(simulator) || os(macOS)
        super.write(NSHomeDirectory())
        #else
        if let bazelWorkspace = getenv(BUILD_WORKSPACE_DIRECTORY) {
            super.write(String(cString: bazelWorkspace))
        } else {
            super.write(INJECTION_KEY)
        }
        #endif

        // Find client platform
        #if os(macOS) || targetEnvironment(macCatalyst)
        var platform = "Mac"
        #elseif os(tvOS)
        var platform = "AppleTV"
        #elseif os(visionOS)
        var platform = "XR"
        #elseif os(watchOS)
        var platform = "Watch"
        #else
        var platform = "iPhone"
        #endif

        #if targetEnvironment(simulator)
        platform += "Simulator"
        #else
        platform += "OS"
        #endif
        #if os(macOS)
        platform += "X"
        #endif

        Reloader.platform = platform

        #if arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "arm64"
        #endif

        // Let server side know the platform and architecture
        sendResponse(.platform, with: platform) {
            self.write(arch)
        }
        if let projectRoot = getenv(INJECTION_PROJECT_ROOT) ??
                           getenv(BUILD_WORKSPACE_DIRECTORY) {
            sendResponse(.projectRoot, with: String(cString: projectRoot))
        }
        sendResponse(.tmpPath, with: NSTemporaryDirectory())
        if let detail = getenv(INJECTION_DETAIL) {
            sendResponse(.detail, with: String(cString: detail))
        }
        if let bazelTarget = getenv(INJECTION_BAZEL_TARGET) {
            sendResponse(.bazelTarget, with: String(cString: bazelTarget))
        }
        if let executable = Bundle.main.executablePath {
            sendResponse(.executable, with: executable)
        }

        Reloader.injectionQueue.sync {
            if !Self.tracingInitialized {
                Self.tracingInitialized = true
                tracingOptions()
            }
        }

        log("\(arch) \(platform) connected to app, waiting for commands.")
        #if !SWIFT_PACKAGE
        if let build = Bundle(for: Self.self)
            .infoDictionary?["CFBundleVersion"] as? String {
            detail("Bundle build #"+build)
        }
        #endif
        _ = Self.networkRecovery
        let stateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("SWIFT_SIM_CLIENT_STATE_CHANGED"), object: nil, queue: nil
        ) { [weak self] _ in self?.sendClientIdentity() }
        defer { NotificationCenter.default.removeObserver(stateObserver) }
        processCommandsFromApp()
        log("Connection lost; waiting for bounded reconnect.")
    }
    
    func tracingOptions() {
        SwiftTrace.injectableSymbol = Reloader.injectableSymbol
        SwiftTrace.defaultMethodExclusions += // CoreFoundation
            #"|\[NS(Method|Tagged|Array|\w*Dict|Date|Data|Timer)|allocWithZone:|__unurl|_trueSelf"#
          + #"|InjectionBundle.|fast_dl"#
        for name in [INJECTION_TRACE_LOOKUP, INJECTION_TRACE_FILTER, INJECTION_TRACE_ALL,
                     INJECTION_TRACE_FRAMEWORKS, INJECTION_TRACE_UIKIT, INJECTION_TRACE] {
            if let value = getenv(name) {
                setVariable(name: name, to: String(cString: value), first: true)
            }
        }
    }
 
    func setVariable(name: String, to value: String, first: Bool) {
        let wasSet = getenv(name) != nil
        if name == INJECTION_DLOPEN_MODE, let mode = Int32(value) {
            DLKit.dlOpenMode = mode
        } else if name == INJECTION_TRACE_FILTER {
            if value == UNSETENV_VALUE {
                if wasSet {
                    SwiftTrace.traceFilterInclude = "."
                }
            } else {
                SwiftTrace.traceFilterInclude = value
            }
        }
        if value == UNSETENV_VALUE {
            unsetenv(name)
            return
        }
        
        setenv(name, value, 1)
        if !first && wasSet {
            return
        }

        switch name {
        /// Custom type lookup on tracing.
        case INJECTION_TRACE_LOOKUP:
            if value.hasPrefix("|") {
                SwiftTrace.defaultLookupExclusions += value
            }
            SwiftTrace.typeLookup = true
        /// Entire App bundle tracing.
        case INJECTION_TRACE_ALL:
            if value.hasPrefix("|") {
                SwiftTrace.defaultMethodExclusions += value
            }
            SwiftTrace.interposeEclusions = SwiftTrace.exclusionRegexp
            appBundleImages { imageName, _, _ in
                if SwiftTrace.interposeMethods(inBundlePath: imageName) == 0,
                   strstr(imageName, "XCT") == nil {
                    self.error("""
                            Unable to interpose to trace image \
                            \(String(cString: imageName)), have you added \
                            "Other Linker Flags" -Xlinker -interposable
                            """)
                }
                SwiftTrace.trace(bundlePath: imageName)
            }
        /// Trace calls to framework e.g. SwiftUI,SwiftUICore
        case INJECTION_TRACE_FRAMEWORKS:
            traceCalls(toFrameworks: value, images: DLKit.appImages.imageList)
        /// Trace UIKit internals using swizzling
        case INJECTION_TRACE_UIKIT:
            var frmwks = value
            if frmwks == "" || frmwks == "1" { frmwks = "UIKitCore" }
            for frmwk in frmwks.components(separatedBy: ",") {
                if let bundle = DLKit.imageMap[frmwk]?.imageName {
                    SwiftTrace.trace(bundlePath: bundle)
                } else {
                    error("Invalid swizzle framework \(frmwk)")
                }
            }
        /// Function and class method tracing on injection.
        case INJECTION_TRACE:
            Reloader.traceHook = { (injected, name) in
                let name = SwiftMeta.demangle(symbol: name) ?? String(cString: name)
                detail("SwiftTracing \(name)")
                return autoBitCast(SwiftTrace.trace(name: name, original: injected)) ?? injected
            }
        default:
            break
        }
    }
    
    func traceCalls(toFrameworks: String, images: [ImageSymbols]) {
        var frmwks = toFrameworks
        if frmwks == "" || frmwks == "1" { frmwks = "SwiftUI,SwiftUICore" }
        for frmwk in frmwks.components(separatedBy: ",") {
            if let dylib = DLKit.imageMap[frmwk] {
                Self.target = dylib
                for image in images {
                    detail("Tracing image \(image)")
                    rebind_symbols_trace(autoBitCast(image.imageHeader),
                                         image.imageSlide, Self.tracer)
                }
            } else {
                error("Invalid trace framework \(frmwk)")
            }
        }
    }

    nonisolated(unsafe)
    static var target: ImageSymbols?
    nonisolated(unsafe)
    static var tracer: STTracer = { existing, symname in
        var traced = existing
        if SwiftTrace.injectableSymbol(symname),
           let info = trie_iterator(existing),
           target?.imageHeader == info.pointee.header,
           let name = SwiftMeta.demangle(symbol: symname) {
            detail("Tracing \(name) \(existing)")
            traced = autoBitCast(SwiftTrace
                .trace(name: "   "+name, original: existing)) ?? existing
        }
        return traced
    }

    func processCommandsFromApp() {
        var loader = Reloader() // InjectionLite injection implementation
        func injectAndSweep(_ dylib: String, prepared: [String: Any]? = nil, identity: [String: Any] = [:]) {
            Self.applyGate.wait()
            let replacementProof: PreparedReplacementProof?
            var callbackCaptures: [PreparedReplacementProof.Capture] = []
            do { replacementProof = try PreparedReplacementProof.parse(prepared?["replacement_proof"]) }
            catch {
                if let prepared {
                    PreparedDeliveryLedger.shared.finish(request: prepared, identity: identity,
                        report: ["succeeded": false, "applied": false, "refresh_acknowledged": false,
                                 "admission": "rejected-before-load", "error_code": "PREPARED_REPLACEMENT_PROOF_INVALID"])
                }
                Self.applyGate.signal(); return
            }
            if let prepared {
                let expiry = (prepared["expires_at_ms"] as? Double ?? 0) / 1_000
                let ready = InjectionWaitForRootReady(expiry)
                let state = InjectionClientExecutionState() as? [String: Any] ?? [:]
                guard ready, PreparedReplacementProof.integer(state["root_revision"]) == PreparedReplacementProof.integer(prepared["baseline_revision"]) else {
                    PreparedDeliveryLedger.shared.finish(request: prepared, identity: identity,
                        report: ["succeeded": false, "applied": false, "refresh_acknowledged": false,
                                 "error_code": ready ? "PREPARED_BASELINE_MISMATCH" : "PREPARED_REQUEST_EXPIRED"])
                    Self.applyGate.signal()
                    return
                }
            }
            if let replacementProof {
                do { callbackCaptures = try replacementProof.capture() }
                catch {
                    if let prepared {
                        PreparedDeliveryLedger.shared.finish(request: prepared, identity: identity,
                            report: ["succeeded": false, "applied": false, "refresh_acknowledged": false,
                                     "admission": "rejected-before-load", "error_code": "PREPARED_OBJC_PREFLIGHT_FAILED"])
                    }
                    Self.applyGate.signal(); return
                }
            }
            if let prepared { PreparedDeliveryFeedback.shared.advance(prepared, phase: "applying") }
            Reloader.injectionNumber += 1
            log("Loading live patch \(URL(fileURLWithPath: dylib).lastPathComponent)")
            if let (image, classes) = Reloader.injectionQueue
                .sync(execute: { loader.loadAndPatch(in: dylib) }) {
                log("Live patch loaded; refreshing instances")
                if let tracing = getenv(INJECTION_TRACE_FRAMEWORKS) {
                    traceCalls(toFrameworks: String(cString: tracing),
                               images: [image])
                }
                let dynamicReplacements = PreparedPatchEvidence.dynamicReplacementCount(in: image)
                let objcCategories = image.entries(withPrefix: "_OBJC_$_CATEGORY_").count
                var refreshRevision: Int?
                let acknowledgement = NotificationCenter.default.addObserver(
                    forName: Notification.Name("SWIFT_SIM_LIVE_REVISION_APPLIED"),
                    object: nil,
                    queue: nil
                ) { notification in
                    refreshRevision = PreparedReplacementProof.integer(notification.userInfo?["revision"])
                }
                if let prepared { PreparedDeliveryFeedback.shared.advance(prepared, phase: "waiting-for-refresh") }
                loader.sweeper.sweepAndRunTests(image: image, classes: classes)
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) {
                    NotificationCenter.default.removeObserver(acknowledgement)
                    let managedPatch = URL(fileURLWithPath: dylib)
                        .lastPathComponent.contains("swift_sim_dynamic")
                    let refreshAcknowledged = refreshRevision != nil
                    let coverage = replacementProof?.evaluate(captures: callbackCaptures, imagePath: image.imagePath, swiftCount: dynamicReplacements)
                    let expectedImage = URL(fileURLWithPath: dylib).standardizedFileURL.resolvingSymlinksInPath().path
                    let actualImage = URL(fileURLWithPath: image.imagePath).standardizedFileURL.resolvingSymlinksInPath().path
                    let applied = replacementProof != nil
                        ? coverage?["complete_replacement_coverage"] as? Bool == true && expectedImage == actualImage
                        : managedPatch ? dynamicReplacements > 0 : true
                    let revisionAdvanced = replacementProof == nil || (refreshRevision ?? 0) > (PreparedReplacementProof.integer(prepared?["baseline_revision"]) ?? 0)
                    let succeeded = applied && (!(managedPatch || replacementProof != nil) || refreshAcknowledged) && revisionAdvanced
                    var report: [String: Any] = [
                        "succeeded": succeeded,
                        "applied": applied,
                        "new_classes": classes.new.count,
                        "objc_categories": objcCategories,
                        "dynamic_replacements": dynamicReplacements,
                        "refresh_acknowledged": refreshAcknowledged,
                        "revision": refreshRevision ?? 0
                    ]
                    if let coverage {
                        report.merge(coverage, uniquingKeysWith: { _, latest in latest })
                        report["admission"] = succeeded ? "applied" : "uncertain-after-load"
                        report["state_uncertain"] = !succeeded
                    }
                    if !applied { report["error_code"] = replacementProof == nil ? "PREPARED_DYNAMIC_REPLACEMENTS_MISSING" : "PREPARED_REPLACEMENT_COVERAGE_UNPROVEN" }
                    else if !refreshAcknowledged { report["error_code"] = "PREPARED_REFRESH_UNCONFIRMED" }
                    else if !revisionAdvanced { report["error_code"] = "PREPARED_REVISION_UNCONFIRMED" }
                    let data = try? JSONSerialization.data(withJSONObject: report)
                    let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    defer { Self.applyGate.signal() }
                    self.log(succeeded ? "Live patch applied" : "Live patch rejected")
                    if let prepared {
                        PreparedDeliveryLedger.shared.finish(request: prepared, identity: self.clientIdentity(), report: report)
                    } else {
                        self.sendResponse(.patchResult, with: json)
                    }
                }
            } else {
                Self.applyGate.signal()
                log("Live patch could not be loaded")
                if let prepared {
                    PreparedDeliveryLedger.shared.finish(request: prepared, identity: self.clientIdentity(),
                        report: ["succeeded": false, "applied": false, "refresh_acknowledged": false,
                                 "admission": "uncertain-after-load", "state_uncertain": true,
                                 "error_code": "PREPARED_LOAD_FAILED"])
                } else {
                    sendResponse(.unhide)
                    sendResponse(.failed)
                }
            }
        }

        while true {
            let commandInt = readInt()
            guard let command = InjectionCommand(rawValue: commandInt) else {
                error("Invalid command rawValue: \(commandInt)")
                break
            }
            switch command {
            case .invalid:
                return error("Connection did not validate. Have you upgraded?")
            case .log:
                if let msg = readString() {
                    print(msg)
                }
            case .xcodePath:
                if let xcodePath = readString() {
                    log("Xcode path: "+xcodePath)
                    Reloader.xcodeDev = xcodePath+"/Contents/Developer"
                }
            case .sendFile:
                guard let path = readString() else {
                    return error("Unable to read path")
                }
                if path.hasSuffix("/") {
                    mkdir(path, 0o755)
                    continue
                }
                recvFile(path)
            case .load:
                guard let dylib = readString() else {
                    return error("Unable to read path")
                }
                injectAndSweep(dylib)
            case .inject:
                guard let dylibName = readString(), let data = readData() else {
                    return error("Unable to read dylib")
                }
                log("Received remote live patch \(dylibName) (\(data.count) bytes)")
                let dylib = NSTemporaryDirectory() + dylibName
                try! data.write(to: URL(fileURLWithPath: dylib))
                injectAndSweep(dylib)
            case .preparedInject:
                guard let json = readString(maxLength: 16_384),
                      let encoded = json.data(using: .utf8),
                      let request = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any],
                      let data = readData(maxLength: 256 * 1_024 * 1_024) else { return }
                let identity = clientIdentity()
                guard PreparedDeliveryLedger.shared.begin(request: request, data: data, identity: identity,
                    deliver: { [weak self] report in self?.sendPreparedReport(report) }) else { continue }
                let requestID = request["request_id"] as! String // validated by the ledger
                let dylib = NSTemporaryDirectory() + "eval_injection_swift_sim_dynamic_" + requestID + ".dylib"
                do {
                    try data.write(to: URL(fileURLWithPath: dylib), options: .atomic)
                    injectAndSweep(dylib, prepared: request, identity: identity)
                } catch {
                    PreparedDeliveryLedger.shared.finish(request: request, identity: identity,
                        report: ["succeeded": false, "applied": false, "refresh_acknowledged": false,
                                 "error_code": "PREPARED_ARTIFACT_WRITE_FAILED"])
                }
            case .metrics:
                guard let metricsJSON = readString(maxLength: 65_536) else {
                    return error("Unable to read metrics JSON")
                }
                if let data = metricsJSON.data(using: .utf8),
                   let metricsDict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let notificationName = metricsDict["notification_name"] as? String {
                    if notificationName == "SWIFT_SIM_ENGINE_CAPABILITIES",
                       metricsDict["prepared_delivery_protocol"] as? Int == 1 {
                        developerLock.lock()
                        developerReady = metricsDict["developer_context_protocol"] as? Int == 1
                        developerLock.unlock()
                        sendClientIdentity(negotiate: true)
                        continue
                    }
                    NotificationCenter.default.post(
                        name: NSNotification.Name(notificationName),
                        object: nil,
                        userInfo: metricsDict
                    )
                }
            case .replayEvents:
                guard let eventsJSON = readString() else {
                    return error("Unable to read touch events JSON")
                }
                #if canImport(UIKit) && !os(watchOS)
                eventsJSON.withCString {
                    InjectionReplayTouchEventsJSON($0)
                }
                #endif
                sendResponse(.replayComplete, with: eventsJSON)
            case .captureEvents:
                #if canImport(UIKit) && !os(watchOS)
                InjectionInstallTouchEventCapture { [weak self] json in
                    self?.sendResponse(.touchEvent, with: String(cString: json))
                }
                #endif
            case .screenshot:
                if let data = screenshotData() {
                    sendResponse(.screenshotData, with: "image/png", data: data)
                } else {
                    sendResponse(.screenshotData, with: "", data: Data())
                }
            case .developerScreenshot:
                guard let json = readString(maxLength: 16_384), let bytes = json.data(using: .utf8),
                      let request = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { return }
                developerScreenshot(request)
            case .developerReportResult:
                guard let json = readString(maxLength: 1_024), let bytes = json.data(using: .utf8),
                      let result = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                      let reportID = result["report_id"] as? String, UUID(uuidString: reportID) != nil,
                      let saved = result["saved"] as? Bool else { return }
                let code = result["error"] as? String
                developerResult(id: reportID, saved: saved,
                    error: code?.hasPrefix("DEVELOPER_") == true ? code : nil)
            case .setenv:
                while let name = readString(), let value = readString() {
                    setVariable(name: name, to: value, first: false)
                    if readInt() != commandInt {
                        break
                    }
                }
            case .EOF:
                return
            default:
                return error("**** @unknown case \(commandInt) **** " +
                             "Do you need to update the InjectionNext package?")
            }
        }
    }
}
#endif
