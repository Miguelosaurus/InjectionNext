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
                "capabilities": ["prepared-delivery-v1", "reconnect-v1", "receipt-v1"]]
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
        defer { disconnect() }
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
            if let prepared {
                let expiry = (prepared["expires_at_ms"] as? Double ?? 0) / 1_000
                let ready = InjectionWaitForRootReady(expiry)
                let state = InjectionClientExecutionState() as? [String: Any] ?? [:]
                guard ready, state["root_revision"] as? Int == prepared["baseline_revision"] as? Int else {
                    PreparedDeliveryLedger.shared.finish(request: prepared, identity: identity,
                        report: ["succeeded": false, "applied": false, "refresh_acknowledged": false,
                                 "error_code": ready ? "PREPARED_BASELINE_MISMATCH" : "PREPARED_REQUEST_EXPIRED"])
                    Self.applyGate.signal()
                    return
                }
            }
            Reloader.injectionNumber += 1
            log("Loading live patch \(URL(fileURLWithPath: dylib).lastPathComponent)")
            if let (image, classes) = Reloader.injectionQueue
                .sync(execute: { loader.loadAndPatch(in: dylib) }) {
                log("Live patch loaded; refreshing instances")
                if let tracing = getenv(INJECTION_TRACE_FRAMEWORKS) {
                    traceCalls(toFrameworks: String(cString: tracing),
                               images: [image])
                }
                let dynamicReplacements = image.swiftSymbols(withSuffixes: ["TI"]).count
                let objcCategories = image.entries(withPrefix: "_OBJC_$_CATEGORY_").count
                var refreshRevision: Int?
                let acknowledgement = NotificationCenter.default.addObserver(
                    forName: Notification.Name("SWIFT_SIM_LIVE_REVISION_APPLIED"),
                    object: nil,
                    queue: nil
                ) { notification in
                    refreshRevision = notification.userInfo?["revision"] as? Int
                }
                loader.sweeper.sweepAndRunTests(image: image, classes: classes)
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) {
                    NotificationCenter.default.removeObserver(acknowledgement)
                    let managedPatch = URL(fileURLWithPath: dylib)
                        .lastPathComponent.contains("swift_sim_dynamic")
                    let refreshAcknowledged = refreshRevision != nil
                    let applied = managedPatch ? dynamicReplacements > 0 : true
                    let succeeded = applied && (!managedPatch || refreshAcknowledged)
                    let report: [String: Any] = [
                        "succeeded": succeeded,
                        "applied": applied,
                        "new_classes": classes.new.count,
                        "objc_categories": objcCategories,
                        "dynamic_replacements": dynamicReplacements,
                        "refresh_acknowledged": refreshAcknowledged,
                        "revision": refreshRevision ?? 0
                    ]
                    let data = try? JSONSerialization.data(withJSONObject: report)
                    let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    defer { Self.applyGate.signal() }
                    self.log(succeeded ? "Live patch applied" : "Live patch rejected")
                    if let prepared {
                        PreparedDeliveryLedger.shared.finish(request: prepared, identity: identity, report: report)
                    } else {
                        self.sendResponse(.patchResult, with: json)
                    }
                }
            } else {
                Self.applyGate.signal()
                log("Live patch could not be loaded")
                if let prepared {
                    PreparedDeliveryLedger.shared.finish(request: prepared, identity: identity,
                        report: ["succeeded": false, "applied": false, "refresh_acknowledged": false,
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
