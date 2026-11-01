//
//  InjectionServer.swift
//  InjectionNext
//
//  Created by John H on 30/05/2024.
//  Copyright © 2024 John Holdsworth. All rights reserved.
//
//  Subclass of SimpleSocket to receive connection from
//  user apps using the InjectionNext Swift Package. An
//  incoming connection will enter runInBackground() on
//  a background thread. Validiates the connection and
//  forwards "commands" to the client app to load dynamic
//  libraries and inject them etc. Also receives feeds
//  of compilation commands from swift-frontend.sh.
//
import Cocoa
import Fortify
import Popen

class InjectionServer: SimpleSocket {

    /// So commands from differnt threads don't get mixed up
    static let clientQueue = DispatchQueue(label: "InjectionCommand")
    static private var connected = [InjectionServer]()
    /// All access to `connected` serialised through clientQueue.
    static var currentClients: [InjectionServer?] {
        return clientQueue.sync { connected.isEmpty ? [nil] : connected }
    }
    /// Current connection to client app. There can be only one.
    static var currentClient: InjectionServer? { currentClients.last ?? nil }
    static var lastAlert: NSAlert?

    /// Sorted last symbols exported by source.
    var exports = [String: [String]]()
    /// Keeps dynamic library file names unique.
    var injectionNumber = 0
    /// Some defaults
    var platform = "iPhoneSimulator"
    var arch = "arm64"
    var tmpPath = "/unset"
    private final class PendingScreenshot {
        let semaphore = DispatchSemaphore(value: 0)
        var mimeType: String?
        var data: Data?
    }
    private var pendingScreenshot: PendingScreenshot?
    private var touchEvents = [String]()
    private var swiftSimMetadata: [String: Any]?
    private final class PendingDeveloperScreenshot {
        let id = UUID().uuidString.lowercased()
        let semaphore = DispatchSemaphore(value: 0)
        var metadata: [String: Any]?
        var data: Data?
    }
    private var pendingDeveloperScreenshot: PendingDeveloperScreenshot?

    func preparedMetadata() -> [String: Any]? { Self.clientQueue.sync { swiftSimMetadata } }
    static func preparedTarget() -> (InjectionServer, [String: Any])? {
        clientQueue.sync {
            guard let client = connected.last, let metadata = client.swiftSimMetadata else { return nil }
            return (client, metadata)
        }
    }

    static func developerTarget(_ selector: [String: Any]) -> (InjectionServer, [String: Any])? {
        clientQueue.sync {
            let matches = connected.compactMap { client -> (InjectionServer, [String: Any])? in
                guard let metadata = client.swiftSimMetadata,
                      let identity = metadata["identity"] as? [String: Any],
                      DeveloperReportStore.matches(identity, selector: selector) else { return nil }
                return (client, metadata)
            }
            return matches.count == 1 ? matches.first : nil
        }
    }

    func requestDeveloperScreenshot(identity: [String: Any]) -> (Data?, String?) {
        let pending = PendingDeveloperScreenshot()
        let request: [String: Any] = ["capture_id": pending.id, "expected_identity": identity]
        guard let encoded = try? JSONSerialization.data(withJSONObject: request),
              let json = String(data: encoded, encoding: .utf8) else { return (nil, "DEVELOPER_REQUEST_INVALID") }
        let accepted = Self.clientQueue.sync { () -> Bool in
            guard pendingDeveloperScreenshot == nil, swiftSimMetadata?["identity"] is [String: Any] else { return false }
            pendingDeveloperScreenshot = pending
            guard writeCommand(InjectionCommand.developerScreenshot.rawValue, with: json) else {
                pendingDeveloperScreenshot = nil; return false
            }
            return true
        }
        guard accepted else { return (nil, "DEVELOPER_BUSY") }
        defer { Self.clientQueue.sync { if pendingDeveloperScreenshot === pending { pendingDeveloperScreenshot = nil } } }
        guard pending.semaphore.wait(timeout: .now() + .seconds(8)) == .success,
              let metadata = pending.metadata else { return (nil, "DEVELOPER_CAPTURE_TIMEOUT") }
        if let code = metadata["error"] as? String { return (nil, code) }
        guard let actual = metadata["identity"] as? [String: Any],
              ["bundle_id", "executable_uuid", "debug_dylib_uuid", "process_nonce", "connection_nonce", "root_revision"].allSatisfy({
                String(describing: actual[$0] ?? "") == String(describing: identity[$0] ?? "")
              }), let image = pending.data, DeveloperReportStore.validJPEG(image) else { return (nil, "DEVELOPER_CAPTURE_CHANGED") }
        return (image, nil)
    }


    func drainTouchEvents() -> [String] {
        Self.clientQueue.sync {
            defer { touchEvents.removeAll() }
            return touchEvents
        }
    }

    func replayTouchEvents(_ json: String) {
        sendCommand(.replayEvents, with: json)
    }

    @discardableResult
    class func alert(_ msg: String, cancel: String? = nil) -> Bool {
        NSLog("\(APP_PREFIX)\(APP_NAME) \(msg)")
        LogBuffer.shared.append("\(APP_NAME) \(msg)", level: "alert")
        if AppDelegate.isSwiftSimEngine {
            return false
        }
        lastAlert = NSAlert()
        lastAlert?.messageText = "\(self)"
        lastAlert?.informativeText = msg
        lastAlert?.alertStyle = .warning
        lastAlert?.addButton(withTitle: "OK")
        if let alt = cancel {
            lastAlert?.addButton(withTitle: alt)
        }
        return lastAlert?.runModal() == .alertFirstButtonReturn
    }

    /// Pops up an alert panel for networking
    @discardableResult
    override public class func error(_ message: String) -> Int32 {
        let msg = String(format:message, strerror(errno))
        LogBuffer.shared.append(msg, level: "error")
        DispatchQueue.main.async { alert(msg) }
        return -1
    }

    // Send command to client app
    func sendCommand(_ command: InjectionCommand, with string: String?) {
        Self.clientQueue.async {
            _ = self.writeCommand(command.rawValue, with: string)
        }
    }

    func requestScreenshot(timeout: DispatchTimeInterval = .seconds(10))
        -> (mimeType: String, data: Data)? {
        let pending = PendingScreenshot()
        var requestStarted = false
        Self.clientQueue.sync {
            if pendingScreenshot == nil {
                pendingScreenshot = pending
                requestStarted = writeCommand(InjectionCommand.screenshot.rawValue, with: nil)
                if !requestStarted {
                    pendingScreenshot = nil
                }
            }
        }
        guard requestStarted else {
            return nil
        }
        guard pending.semaphore.wait(timeout: .now() + timeout) == .success,
              let mimeType = pending.mimeType, !mimeType.isEmpty,
              let data = pending.data, !data.isEmpty else {
            Self.clientQueue.sync {
                if pendingScreenshot === pending {
                    pendingScreenshot = nil
                }
            }
            return nil
        }
        Self.clientQueue.sync {
            if pendingScreenshot === pending {
                pendingScreenshot = nil
            }
        }
        return (mimeType, data)
    }

    // Write message into Xcode console of client app.
    open func log(_ msg: String) {
        NSLog("\(APP_PREFIX)\(APP_NAME) \(msg)")
        LogBuffer.shared.append(msg, level: "info")
        sendCommand(.log, with: APP_PREFIX+msg)
    }
    open func error(_ msg: String) {
        log("⚠️ "+msg)
    }

    lazy var copyPlugIns: () = {
        let pattern = "/tmp/InjectionNext.PlugIns/*.xctest"
        if platform == "iPhoneOS" && isLocalClient {
            if let errors = Popen.system("""
                rm -rf "\(tmpPath)"/*.xctest; \
                rsync -a \(pattern) "\(tmpPath)"
                """, errors: true) {
                error("Copy *.xctest failed: "+errors)
            }
            return
        }
        guard let plugins = Glob(pattern: pattern) else { return }
        for plugin in plugins {
            writeCommand(InjectionCommand.log.rawValue, with: APP_PREFIX+"Sending "+plugin)
            let url = URL(fileURLWithPath: plugin)
            let dest = tmpPath+"/"+url.lastPathComponent
            writeCommand(InjectionCommand.sendFile.rawValue, with: dest+"/")
            writeCommand(InjectionCommand.sendFile.rawValue, with: dest+"/_CodeSignature/")
            for file in [url.deletingPathExtension().lastPathComponent,
                         "Info.plist", "/_CodeSignature/CodeResources"] {
                writeCommand(InjectionCommand.sendFile.rawValue, with: dest+"/"+file)
                sendFile(url.appendingPathComponent(file).path)
            }
        }
    }()

    // Simple validation to weed out invalid connections
    func validateConnection() -> Bool {
        guard readInt() == INJECTION_VERSION,
              let injectionKey = readString() else { return false }
        guard injectionKey.hasPrefix(NSHomeDirectory()) else {
            error("Invalid INJECTION_KEY: "+injectionKey)
            return false
        }
        return true
    }

    // On a new connection starts executing here
    override func runInBackground() {
        defer { disconnect() }
        do {
            try Fortify.protect {
                if AppDelegate.isSwiftSimEngine {
                    isLocalClient = false
                }
                guard validateConnection() else {
                    sendCommand(.invalid, with: nil)
                    error("Connection did not validate.")
                    return
                }
                DispatchQueue.main.async {
                    InjectionHybrid.pendingFilesChanged.removeAll()
                    // Reset repository locked state on app reconnect (relaunch)
                    if InjectionHybrid.isRepositoryLocked {
                        InjectionHybrid.isRepositoryLocked = false
                        InjectionHybrid.gitLockPath = nil
                        self.log("Repository lock cleared - injection resumed")
                    }
                }
                processResponses()
            }
        } catch {
            self.error("\(self) error \(error)")
        }
        Self.clientQueue.sync {
            Self.connected.removeAll { $0 === self }
            AppDelegate.ui.setMenuIcon(MonitorXcode
                .runningXcode != nil ? .ready : .idle)
        } // flush messages and de-register
    }

    func processResponses() {
        sendCommand(.xcodePath, with: Defaults.xcodePath)
        if AppDelegate.isSwiftSimEngine {
            sendCommand(.metrics, with: "{\"notification_name\":\"SWIFT_SIM_ENGINE_CAPABILITIES\",\"prepared_delivery_protocol\":1,\"developer_context_protocol\":1}")
        }
        AppDelegate.restartLastWatcher()

        while true {
            let responseInt = readInt()
            guard let response = InjectionResponse(rawValue: responseInt) else {
                error("Invalid responseInt: \(responseInt)")
                break
            }
            switch response {
            case .platform:
                if let platform = readString(), let arch = readString() {
                    log("Platform connected: "+platform)
                    self.platform = platform
                    Reloader.arch = arch
                    self.arch = arch
                } else {
                    error("**** Bad platform ****")
                    return
                }
            case .tmpPath:
                if let tmpPath = readString() {
                    debug("Tmp path: "+tmpPath)
                    if tmpPath.contains("/Xcode/UserData/Previews/") {
                        return
                    }
                    self.tmpPath = tmpPath
                    self.tmpPath[#"/$"#] = "" // strip trailing slash
                    Self.clientQueue.async {
                        Self.connected.append(self)
                        AppDelegate.ui.setMenuIcon(.ok)
                        ConfigStore.shared.sendEnvVars(to: self)
                        if Defaults.mcpServer {
                            self.sendCommand(.captureEvents, with: nil)
                        }
                    }
                } else {
                    error("**** Bad tmp ****")
                }
                if MonitorXcode.runningXcode == nil &&
                    AppDelegate.watchers.isEmpty &&
                    AppDelegate.ui.updatePatchUnpatch() == .unpatched {
                    error("""
                        Xcode not launched via app. Injection will not be possible \ 
                        unless you file-watch a project and Xcode logs are available. \
                        You can add an env var INJECTION_PROJECT_ROOT to your scheme \
                        with value $(SRCROOT) to auto file-watch this project.
                        """)
                }
                if !AppDelegate.watchers.isEmpty {
                    log("Watching directory: " +
                        AppDelegate.watchers.keys.joined(separator: ", "))
                }
            case .projectRoot:
                if let projectRoot = readString() {
                    log("Auto-watching project: \(projectRoot)")
                    DispatchQueue.main.sync {
                        AppDelegate.ui.watch(path: projectRoot)
                        Self.lastAlert?.buttons.last?.performClick(self)
                        Self.lastAlert = nil
                    }
                } else {
                    error("**** Bad root ****")
                }
            case .executable:
                if let executable = readString() {
                    Reloader.appName = URL(fileURLWithPath:
                                            executable).lastPathComponent
                }
            case .screenshotData:
                guard let mimeType = readString(), let data = readData() else {
                    error("**** Bad screenshot ****")
                    return
                }
                Self.clientQueue.sync {
                    pendingScreenshot?.mimeType = mimeType
                    pendingScreenshot?.data = data
                    pendingScreenshot?.semaphore.signal()
                }
            case .developerScreenshotData:
                guard let json = readString(maxLength: 16_384), let encoded = json.data(using: .utf8),
                      let metadata = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any],
                      let data = readData(maxLength: 1_048_576) else { return }
                Self.clientQueue.sync {
                    guard let pending = pendingDeveloperScreenshot,
                          metadata["capture_id"] as? String == pending.id else { return }
                    pending.metadata = metadata; pending.data = data; pending.semaphore.signal()
                }
            case .developerReport:
                guard let json = readString(maxLength: 32_768), let encoded = json.data(using: .utf8),
                      let envelope = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any],
                      let metadata = envelope["metadata"] as? [String: Any],
                      let capturedIdentity = envelope["identity"] as? [String: Any],
                      let image = readData(maxLength: 1_048_576),
                      let reportID = metadata["report_id"] as? String, UUID(uuidString: reportID) != nil else { return }
                let observed = preparedMetadata()?["identity"] as? [String: Any] ?? [:]
                guard AppDelegate.isSwiftSimEngine,
                      ["bundle_id", "executable_uuid", "debug_dylib_uuid", "process_nonce", "connection_nonce"].allSatisfy({
                          capturedIdentity[$0] is String && capturedIdentity[$0] as? String == observed[$0] as? String
                      }) else { developerReportResult(id: reportID, saved: false, error: "DEVELOPER_IDENTITY_MISMATCH"); continue }
                guard !PreparedDeliveryEngine.hasPending(for: observed) else {
                    developerReportResult(id: reportID, saved: false, error: "DEVELOPER_BUSY"); continue
                }
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try DeveloperReportStore.shared.save(metadata: metadata, image: image, identity: capturedIdentity)
                        self.developerReportResult(id: reportID, saved: true)
                    } catch {
                        self.developerReportResult(id: reportID, saved: false,
                            error: (error as? DeveloperReportStore.Failure)?.rawValue ?? "DEVELOPER_REPORT_UNAVAILABLE")
                    }
                }
            case .touchEvent:
                if let json = readString() {
                    Self.clientQueue.sync {
                        touchEvents.append(json)
                    }
                } else {
                    error("**** Bad touch event ****")
                }
            case .replayComplete:
                if readString() == nil {
                    error("**** Bad replay completion ****")
                }
            case .swiftSimClient:
                guard let json = readString(maxLength: 16_384),
                      let data = json.data(using: .utf8),
                      let metadata = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      metadata["protocol"] as? Int == 1,
                      let identity = metadata["identity"] as? [String: Any],
                      let capabilities = metadata["capabilities"] as? [String], capabilities.count <= 16,
                      ["bundle_id", "build_number", "executable_uuid", "debug_dylib_uuid", "process_nonce", "connection_nonce"].allSatisfy({ key in
                          guard let value = identity[key] as? String else { return false }
                          return value.utf8.count <= 256
                      }), identity["is_active"] is Bool, identity["root_ready"] is Bool,
                      let revision = identity["root_revision"] as? Int, revision >= 0 else { return }
                Self.clientQueue.sync { swiftSimMetadata = metadata }
            case .detail:
                if let detail = readString() {
                    setenv(INJECTION_DETAIL, detail, 1)
                }
            case .bazelTarget:
                if let target = readString() {
                    log("Received Bazel target: \(target)")
                    BazelActionQueryHandler.cachedAppTarget = target
                    // Set environment variable so Bazel parsers can use this target
                    setenv(INJECTION_BAZEL_TARGET, target, 1)
                } else {
                    error("**** Bad Bazel target ****")
                }
            case .injected:
                AppDelegate.ui.setMenuIcon(.ok)
                ControlServer.recordInjectionResult(succeeded: true)
            case .failed:
                AppDelegate.ui.setMenuIcon(.error)
                ControlServer.recordInjectionResult(succeeded: false)
            case .patchResult:
                guard let json = readString(maxLength: 65_536),
                      let data = json.data(using: .utf8),
                      let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    error("**** Bad patch result ****")
                    ControlServer.recordInjectionResult(succeeded: false)
                    continue
                }
                if report["request_id"] is String {
                    PreparedDeliveryEngine.record(report, from: self)
                    continue
                }
                let succeeded = report["succeeded"] as? Bool == true
                AppDelegate.ui.setMenuIcon(succeeded ? .ok : .error)
                ControlServer.recordInjectionResult(
                    succeeded: succeeded,
                    report: report
                )
            case .unhide:
                log("Injection could not load. If this was due to a default " +
                    "argument. Select the app's menu item \"Unhide Symbols\".")
            case .exit:
                log("**** client disconnected ****")
                return
            @unknown default:
                Self.error("**** @unknown response case \(responseInt) ****")
                return
            }
        }
    }

    private func developerReportResult(id: String, saved: Bool, error: String? = nil) {
        var result: [String: Any] = ["report_id": id, "saved": saved]
        if let error { result["error"] = error }
        guard let bytes = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: bytes, encoding: .utf8) else { return }
        sendCommand(.developerReportResult, with: json)
    }
}
