//
//  ControlServer.swift
//  InjectionNext
//
//  Local Unix domain socket control server for MCP integration.
//  Listens for JSON commands from the bundled MCP server and
//  maps them to existing AppDelegate actions.
//

import Cocoa

// MARK: - Control Server

class ControlServer {

    static let compatibilityPort: UInt16 = 8919
    static var socketPath: String {
        ProcessInfo.processInfo.environment["SWIFT_SIM_ENGINE_SOCKET"]
            ?? "/tmp/InjectionNext-control.sock"
    }
    static var servicedRequest = false
    static var shared: ControlServer?
    static var injectionRequestID = 0
    static var completedInjectionRequestID = 0
    static var lastInjectionSucceeded: Bool?
    static var lastInjectionCompletedAt: TimeInterval?
    static var lastPatchReport: [String: Any]?

    private static let registrations = CompilationRegistrationRegistry(instanceNonce: PreparedDeliveryEngine.instanceNonce, enqueue: { operation in NextCompiler.compileQueue.async(execute: operation) })

    private var serverSocket: Int32 = -1
    private let queue = DispatchQueue(label: "ControlServer", attributes: .concurrent)

    static func start() {
        guard shared == nil else { return }
        if !AppDelegate.isSwiftSimEngine {
            CompatibilityControlServer.startServer(":\(compatibilityPort)")
        }
        shared = ControlServer()
        shared?.listen()
    }

    private func listen() {
        queue.async { [weak self] in
            guard let self = self else { return }

            self.serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
            guard self.serverSocket >= 0 else {
                NSLog("\(APP_PREFIX)ControlServer: socket() failed")
                return
            }

            let socketPath = Self.socketPath
            guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
                NSLog("\(APP_PREFIX)ControlServer: socket path too long: \(socketPath)")
                close(self.serverSocket)
                return
            }

            unlink(socketPath)

            var addr = sockaddr_un()
            addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)
            let sunPathSize = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
            withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
                socketPath.withCString { source in
                    if let baseAddress = buffer.baseAddress {
                        strncpy(baseAddress.assumingMemoryBound(to: CChar.self),
                                source, sunPathSize - 1)
                    }
                }
            }

            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(self.serverSocket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }

            guard bindResult == 0 else {
                NSLog("\(APP_PREFIX)ControlServer: bind() failed at \(socketPath): \(String(cString: strerror(errno)))")
                close(self.serverSocket)
                return
            }
            chmod(socketPath, S_IRUSR | S_IWUSR)

            guard Darwin.listen(self.serverSocket, 5) == 0 else {
                NSLog("\(APP_PREFIX)ControlServer: listen() failed")
                close(self.serverSocket)
                return
            }

            NSLog("\(APP_PREFIX)ControlServer: listening at \(socketPath)")

            while true {
                let clientSocket = accept(self.serverSocket, nil, nil)
                guard clientSocket >= 0 else { continue }
                self.queue.async {
                    self.handleClient(clientSocket)
                }
            }
        }
    }

    private func handleClient(_ sock: Int32) {
        defer { close(sock) }
        guard let data = try? CompilationControlTransport.read(sock) else {
            sendResponse(sock, success: false, error: "Control request incomplete, oversized or timed out")
            return
        }

        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            sendResponse(sock, success: false, error: "Invalid JSON or missing 'action'")
            return
        }

        if data.count > 64 * 1024 && action != "register_compilation_map" {
            sendResponse(sock, success: false, error: "Request too large")
            return
        }
        let result = executeAction(action, params: json)
        sendResponse(sock, success: result.success, data: result.data, error: result.error)
        Self.servicedRequest = true
    }

    private func sendResponse(_ sock: Int32, success: Bool, data: [String: Any]? = nil, error: String? = nil) {
        var response: [String: Any] = ["success": success]
        if let error = error { response["error"] = error }
        if let data = data { response["data"] = data }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: response),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }
        _ = CompilationControlTransport.write(Data((jsonStr + "\n").utf8), socket: sock)
    }

    struct ActionResult {
        let success: Bool
        let data: [String: Any]?
        let error: String?

        static func ok(_ data: [String: Any]? = nil) -> ActionResult {
            ActionResult(success: true, data: data, error: nil)
        }
        static func fail(_ error: String) -> ActionResult {
            ActionResult(success: false, data: nil, error: error)
        }
    }

    private func executeAction(_ action: String, params: [String: Any]) -> ActionResult {
        switch action {

        case "status":
            return getStatus()

        case "developer_context":
            guard AppDelegate.isSwiftSimEngine else { return .fail("DEVELOPER_PRIVATE_ENGINE_REQUIRED") }
            return developerContext(params)

        case "developer_report":
            guard AppDelegate.isSwiftSimEngine else { return .fail("DEVELOPER_PRIVATE_ENGINE_REQUIRED") }
            do { return .ok(try DeveloperReportStore.shared.latest(selector: params, reportID: params["report_id"] as? String)) }
            catch { return .fail((error as? DeveloperReportStore.Failure)?.rawValue ?? "DEVELOPER_REPORT_UNAVAILABLE") }

        case "developer_tool":
            guard AppDelegate.isSwiftSimEngine else { return .fail("DEVELOPER_PRIVATE_ENGINE_REQUIRED") }
            return developerTool(params)

        case "watch_project":
            guard let path = params["path"] as? String else {
                return .fail("Missing 'path' parameter")
            }
            return watchProject(path: path)

        case "stop_watching":
            return stopWatching()

        case "launch_xcode":
            return launchXcode()

        case "intercept_compiler":
            return interceptCompiler()

        case "enable_devices":
            let enable = params["enable"] as? Bool ?? true
            return enableDevices(enable: enable)

        case "unhide_symbols":
            return unhideSymbols()

        case "get_last_error":
            return getLastError()

        case "take_screenshot":
            return takeScreenshot()

        case "get_touch_events":
            return getTouchEvents()

        case "replay_touch_events":
            return replayTouchEvents(params: params)

        case "prepare_swiftui_source":
            return prepareSwiftUISource()

        case "prepare_swiftui_project":
            return prepareSwiftUIProject()

        case "set_xcode_path":
            guard let path = params["path"] as? String else {
                return .fail("Missing 'path' parameter")
            }
            return setXcodePath(path: path)

        case "get_logs":
            let since = params["since"] as? TimeInterval ?? 0
            let limit = max(0, min(params["limit"] as? Int ?? 200, 500))
            return getLogs(since: since, limit: limit)

        case "clear_logs":
            return clearLogs()

        case "compilation_registration_status":
            guard AppDelegate.isSwiftSimEngine else { return .fail("COMPILATION_REGISTRATION_PRIVATE_ENGINE_REQUIRED") }
            return Self.registrations.query(params)

        case "register_compilation_map":
            guard AppDelegate.isSwiftSimEngine else { return .fail("COMPILATION_REGISTRATION_PRIVATE_ENGINE_REQUIRED") }
            return Self.registrations.begin(params, apply: self.commitCompilationMap)

        case "register_compilations":
            guard !AppDelegate.isSwiftSimEngine else { return .fail("COMPILATION_REGISTRATION_TRANSACTION_REQUIRED") }
            guard let commands = params["commands"] as? [[String: Any]] else {
                return .fail("Missing 'commands' parameter")
            }
            return registerCompilations(commands)

        case "inject_source":
            guard let path = params["path"] as? String else {
                return .fail("Missing 'path' parameter")
            }
            return injectSource(path: path)

        case "prepare_dylib":
            guard AppDelegate.isSwiftSimEngine else { return .fail("PREPARED_PRIVATE_ENGINE_REQUIRED") }
            return PreparedDeliveryEngine.prepare(params)

        case "inject_prepared":
            guard AppDelegate.isSwiftSimEngine else { return .fail("PREPARED_PRIVATE_ENGINE_REQUIRED") }
            return PreparedDeliveryEngine.inject(params)

        case "prepared_receipt":
            guard AppDelegate.isSwiftSimEngine else { return .fail("PREPARED_PRIVATE_ENGINE_REQUIRED") }
            return PreparedDeliveryEngine.query(params)

        case "inject_dylib":
            guard let path = params["path"] as? String,
                  let source = params["source"] as? String else {
                return .fail("Missing 'path' or 'source' parameter")
            }
            return injectDylib(path: path, source: source)

        default:
            return .fail("Unknown action: \(action)")
        }
    }

    // MARK: - Actions

    private func getStatus() -> ActionResult {
        var result = [String: Any]()
        var compilationPlatform = "iPhoneOS"
        DispatchQueue.main.sync {
            guard let delegate = AppDelegate.ui else { return }
            result["xcode_running"] = MonitorXcode.runningXcode != nil
            result["xcode_path"] = Defaults.xcodePath
            result["compiler_intercepted"] = delegate.updatePatchUnpatch() == .patched
            result["devices_enabled"] = delegate.enableDevicesItem.state == .on
            result["watching_directories"] = Array(AppDelegate.watchers.keys)
            result["has_connected_client"] = InjectionServer.currentClient != nil
            result["auto_restart_xcode"] = Defaults.xcodeRestart
            result["last_error"] = NextCompiler.lastError
            result["last_source"] = NextCompiler.lastSource
            result["injection_state"] = ConfigStore.shared.injectionState.rawValue
            result["engine_mode"] = AppDelegate.isSwiftSimEngine
            result["engine_instance_nonce"] = PreparedDeliveryEngine.instanceNonce
            result["prepared_delivery_protocol"] = 1
            result["prepared_replacement_proof_protocol"] = PreparedDeliveryEngine.replacementProofProtocol
            result["compilation_registration_protocol"] = 1
            if let (_, metadata) = InjectionServer.preparedTarget() {
                result["client_identity"] = metadata["identity"]
                result["client_capabilities"] = metadata["capabilities"]
            }
            result["codesigning_identity_configured"] =
                !(ConfigStore.shared.codesigningIdentity ?? "").isEmpty
            result["project_path"] = ConfigStore.shared.projectPath
            compilationPlatform = InjectionServer.currentClient?.platform ?? "iPhoneOS"
            result["injection_request_id"] = Self.injectionRequestID
            result["completed_injection_request_id"] =
                Self.completedInjectionRequestID
            result["last_injection_succeeded"] = Self.lastInjectionSucceeded
            result["last_injection_completed_at"] =
                Self.lastInjectionCompletedAt
            result["last_patch_report"] = Self.lastPatchReport
        }
        // Keep dictionary reads with compiler-map mutation, outside the main
        // thread block so a compiler waiting on UI work cannot deadlock status.
        result["captured_compilations"] = NextCompiler.compileQueue.sync {
            FrontendServer.frontendRecompiler(for: compilationPlatform).compilations.count
        }
        return .ok(result)
    }

    private func commitCompilationMap(_ commands: [[String: Any]], permit: () -> Bool) throws -> CompilationRegistrationRegistry.Outcome {
        struct InvalidMap: Error {}
        var maps: [String: [String: NextCompiler.Compilation]] = [:]
        for command in commands {
            guard let arguments = command["arguments"] as? [String], let directory = command["working_directory"] as? String else { throw InvalidMap() }
            var parser = FrontendServer.CompilationArgParser(); parser.workingDir = directory
            var index = 2
            while index < arguments.count {
                let argument = arguments[index]; index += 1
                parser.process(arg: argument) {
                    guard index < arguments.count else { return nil }
                    defer { index += 1 }; return arguments[index]
                }
            }
            let sources = parser.primaries.isEmpty ? parser.swiftFiles.components(separatedBy: .newlines).filter { !$0.isEmpty } : parser.primaries
            guard !sources.isEmpty else { throw InvalidMap() }
            let compilation = NextCompiler.Compilation(arguments: parser.args, swiftFiles: parser.swiftFiles, workingDir: parser.workingDir, env: nil)
            for source in sources { maps[parser.platform, default: [:]][source] = compilation }
        }
        guard !maps.isEmpty, permit() else { throw InvalidMap() }
        // Install from a fully parsed map on the compiler owner queue. Never call
        // store(): pendingSource callbacks must not turn metadata resume into an injection.
        // One atomic publication covers every platform. A crash or a failed
        // write cannot expose one platform from a new map beside another old map.
        try CompilationRegistrationSnapshotStore.write(JSONEncoder().encode(maps), to: FrontendServer.registrationCacheURL)
        for (platform, map) in maps {
            let compiler = FrontendServer.frontendRecompiler(for: platform)
            compiler.compilations = map; compiler.lastCompilation = nil; compiler.modified = false
        }
        // Durable cache compression is not a prerequisite to a qualified map.
        // ReadCache prefers the freshly written uncompressed cache (below).
        let sources = maps.values.flatMap { $0.keys }
        return CompilationRegistrationRegistry.Outcome(registeredCount: sources.count, sources: sources)
    }

    private func registerCompilations(_ commands: [[String: Any]]) -> ActionResult {
        var registered = [String]()
        for command in commands {
            guard let arguments = command["arguments"] as? [String],
                  arguments.count >= 2,
                  arguments[0] == "-frontend",
                  arguments[1] == "-c" else { continue }
            var parser = FrontendServer.CompilationArgParser()
            parser.workingDir = command["working_directory"] as? String
                ?? ConfigStore.shared.projectPath
            var index = 2
            while index < arguments.count {
                let argument = arguments[index]
                index += 1
                parser.process(arg: argument) {
                    guard index < arguments.count else { return nil }
                    defer { index += 1 }
                    return arguments[index]
                }
            }
            let sources = parser.primaries.isEmpty
                ? parser.swiftFiles.components(separatedBy: .newlines)
                    .filter { !$0.isEmpty }
                : parser.primaries
            guard !sources.isEmpty else { continue }
            let compilation = NextCompiler.Compilation(
                arguments: parser.args,
                swiftFiles: parser.swiftFiles,
                workingDir: parser.workingDir,
                env: nil
            )
            let recompiler = FrontendServer.frontendRecompiler(for: parser.platform)
            for source in sources {
                recompiler.store(compilation: compilation, for: source)
                registered.append(source)
            }
            recompiler.writeCache()
        }
        return .ok([
            "registered_count": registered.count,
            "sources": Array(Set(registered)).sorted()
        ])
    }

    private func injectSource(path: String) -> ActionResult {
        let source = URL(fileURLWithPath: path).standardized.path
        guard source.hasSuffix(".swift"),
              FileManager.default.fileExists(atPath: source),
              let root = AppDelegate.alreadyWatching(source),
              let watcher = AppDelegate.watchers[root] else {
            return .fail("Source is not a watched Swift file: \(source)")
        }
        Self.injectionRequestID += 1
        Self.lastInjectionSucceeded = nil
        let requestID = Self.injectionRequestID
        DispatchQueue.main.async {
            watcher.injectRequested(source: source)
        }
        return .ok(["request_id": requestID, "source": source])
    }

    private func injectDylib(path: String, source: String) -> ActionResult {
        let dylib = URL(fileURLWithPath: path).standardized.path
        guard dylib.hasSuffix(".dylib"),
              FileManager.default.fileExists(atPath: dylib) else {
            return .fail("Dynamic replacement library is missing: \(dylib)")
        }
        guard let client = InjectionServer.currentClient else {
            return .fail("No live-enabled app is connected")
        }
        Self.injectionRequestID += 1
        Self.lastInjectionSucceeded = nil
        Self.lastPatchReport = nil
        let requestID = Self.injectionRequestID
        let recompiler = FrontendServer.frontendRecompiler(for: client.platform)
        DispatchQueue.main.async {
            _ = recompiler.injectPreparedDylib(path: dylib, source: source)
        }
        return .ok(["request_id": requestID, "source": source])
    }

    static func recordInjectionResult(succeeded: Bool,
                                      report: [String: Any]? = nil) {
        guard isSwiftSimEngine else { return }
        completedInjectionRequestID = injectionRequestID
        lastInjectionSucceeded = succeeded
        lastInjectionCompletedAt = Date.timeIntervalSinceReferenceDate
        lastPatchReport = report
    }

    private static var isSwiftSimEngine: Bool {
        AppDelegate.isSwiftSimEngine
    }

    private func watchProject(path: String) -> ActionResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return .fail("Path does not exist: \(path)")
        }
        DispatchQueue.main.sync {
            Reloader.xcodeDev = Defaults.xcodePath + "/Contents/Developer"
            AppDelegate.ui.watch(path: path)
        }
        return .ok(["watching": path])
    }

    private func stopWatching() -> ActionResult {
        DispatchQueue.main.sync {
            AppDelegate.watchers.removeAll()
            AppDelegate.lastWatched = nil
            AppDelegate.ui.watchDirectoryItem.state = .off
        }
        return .ok()
    }

    private func launchXcode() -> ActionResult {
        DispatchQueue.main.sync {
            if MonitorXcode.runningXcode == nil {
                _ = MonitorXcode()
            }
        }
        return .ok(["xcode_path": Defaults.xcodePath])
    }

    private func interceptCompiler() -> ActionResult {
        var state = ""
        DispatchQueue.main.sync {
            guard let delegate = AppDelegate.ui else { return }
            let currentState = delegate.updatePatchUnpatch()
            state = currentState == .patched ? "patched" : "unpatched"
        }
        return .ok(["compiler_state": state,
                     "note": "Use Xcode UI to toggle interception (requires user confirmation alert)"])
    }

    private func enableDevices(enable: Bool) -> ActionResult {
        DispatchQueue.main.sync {
            guard let delegate = AppDelegate.ui else { return }
            let currentlyEnabled = delegate.enableDevicesItem.state == .on
            if enable != currentlyEnabled {
                delegate.deviceEnable(NSMenuItem())
            }
        }
        return .ok(["devices_enabled": enable])
    }

    private func unhideSymbols() -> ActionResult {
        Unhider.startUnhide()
        return .ok()
    }

    private func getLastError() -> ActionResult {
        let error = NextCompiler.lastError ?? "No error."
        return .ok(["error": error])
    }

    private func takeScreenshot() -> ActionResult {
        guard let client = InjectionServer.currentClient else {
            return .fail("No connected client app")
        }
        guard let screenshot = client.requestScreenshot() else {
            return .fail("Unable to capture screenshot from client app")
        }
        return .ok([
            "mimeType": screenshot.mimeType,
            "data": screenshot.data.base64EncodedString(),
            "bytes": screenshot.data.count
        ])
    }

    private func developerContext(_ params: [String: Any]) -> ActionResult {
        guard ["bundle_id", "executable_uuid", "debug_dylib_uuid"].allSatisfy({
            guard let value = params[$0] as? String else { return false }; return !value.isEmpty && value.utf8.count <= 256
        }), params["screenshot"] == nil || params["screenshot"] is Bool else { return .fail("DEVELOPER_REQUEST_INVALID") }
        guard let (client, metadata) = InjectionServer.developerTarget(params),
              let identity = metadata["identity"] as? [String: Any] else { return .fail("DEVELOPER_IDENTITY_MISMATCH") }
        guard let capabilities = metadata["capabilities"] as? [String], capabilities.contains("developer-context-v1") else {
            return .fail("DEVELOPER_CONTEXT_UNSUPPORTED")
        }
        var result: [String: Any] = ["schema_version": 1, "identity": identity, "capabilities": capabilities]
        if let delivery = PreparedDeliveryEngine.lastDeveloperDelivery(for: identity) { result["last_delivery"] = delivery }
        if params["screenshot"] as? Bool == true {
            guard identity["is_active"] as? Bool == true else { return .fail("DEVELOPER_NOT_FOREGROUND") }
            guard !PreparedDeliveryEngine.hasPending(for: identity) else { return .fail("DEVELOPER_BUSY") }
            let (image, error) = client.requestDeveloperScreenshot(identity: identity)
            guard let image else { return .fail(error ?? "DEVELOPER_CAPTURE_UNAVAILABLE") }
            result["screenshot"] = ["mimeType": "image/jpeg", "bytes": image.count, "data": image.base64EncodedString()]
        }
        return .ok(result)
    }

    private func developerTool(_ params: [String: Any]) -> ActionResult {
        guard let operationID = params["operation_id"] as? String, UUID(uuidString: operationID) != nil,
              let tool = params["tool"] as? String, ["appearance", "refresh"].contains(tool),
              tool != "appearance" || ["app-default", "light", "dark"].contains(params["value"] as? String ?? ""),
              ["bundle_id", "executable_uuid", "debug_dylib_uuid", "process_nonce", "connection_nonce"].allSatisfy({
                  guard let value = params[$0] as? String else { return false }; return !value.isEmpty && value.utf8.count <= 256
              }) else { return .fail("DEVELOPER_REQUEST_INVALID") }
        guard let (client, metadata) = InjectionServer.developerTarget(params),
              let identity = metadata["identity"] as? [String: Any],
              ["process_nonce", "connection_nonce"].allSatisfy({ params[$0] as? String == identity[$0] as? String }) else {
            return .fail("DEVELOPER_IDENTITY_MISMATCH")
        }
        guard let capabilities = metadata["capabilities"] as? [String], capabilities.contains("developer-context-v1") else {
            return .fail("DEVELOPER_CONTEXT_UNSUPPORTED")
        }
        guard identity["is_active"] as? Bool == true, identity["root_ready"] as? Bool == true else {
            return .fail("DEVELOPER_NOT_FOREGROUND")
        }
        guard !PreparedDeliveryEngine.hasPending(for: identity) else { return .fail("DEVELOPER_BUSY") }
        var request: [String: Any] = ["operation_id": operationID.lowercased(), "tool": tool]
        if tool == "appearance" { request["value"] = params["value"] }
        let (result, error) = client.requestDeveloperTool(request, identity: identity)
        guard let result else { return .fail(error ?? "DEVELOPER_TOOL_UNCONFIRMED") }
        return .ok(["schema_version": 1, "identity": identity, "operation_id": operationID.lowercased(), "result": result])
    }

    private func getTouchEvents() -> ActionResult {
        #if !INJECTION_III_APP
        guard let client = InjectionServer.currentClient else {
            return .fail("No connected client app")
        }
        let events = client.drainTouchEvents().compactMap { json -> Any? in
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        return .ok(["events": events])
        #else
        return .fail("Not available")
        #endif
    }

    private func replayTouchEvents(params: [String: Any]) -> ActionResult {
        #if !INJECTION_III_APP
        guard let client = InjectionServer.currentClient else {
            return .fail("No connected client app")
        }
        let payload: Any
        if let events = params["events"] as? [Any] {
            payload = ["events": events]
        } else {
            payload = params
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return .fail("Invalid touch event JSON payload")
        }
        client.replayTouchEvents(json)
        let count = (payload as? [String: Any])?["events"] as? [Any]
        return .ok(["events": count?.count ?? 0])
        #else
        return .fail("Not available")
        #endif
    }

    private func prepareSwiftUISource() -> ActionResult {
        guard let lastSource = NextCompiler.lastSource else {
            return .fail("No source file currently being edited")
        }
        DispatchQueue.main.sync {
            AppDelegate.ui.prepareSwiftUI(source: lastSource)
        }
        return .ok(["source": lastSource])
    }

    private func prepareSwiftUIProject() -> ActionResult {
        DispatchQueue.main.sync {
            AppDelegate.ui.prepareProject(AppDelegate.ui.patchCompilerItem)
        }
        return .ok()
    }

    private func setXcodePath(path: String) -> ActionResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return .fail("Xcode not found at: \(path)")
        }
        DispatchQueue.main.sync {
            Defaults.xcodeDefault = path
            AppDelegate.ui.updatePatchUnpatch()
        }
        return .ok(["xcode_path": path])
    }

    private func getLogs(since: TimeInterval, limit: Int) -> ActionResult {
        let logs = LogBuffer.shared.get(since: since, limit: limit)
        return .ok(["logs": logs, "count": LogBuffer.shared.count])
    }

    private func clearLogs() -> ActionResult {
        LogBuffer.shared.clear()
        return .ok()
    }

    private final class CompatibilityControlServer: SimpleSocket {
        override func run() {
            let response: [String: Any] = [
                "success": false,
                "error": "InjectionNext now uses a Unix domain socket for MCP control. " +
                "Upgrade your mcp-server or use the version bundled inside InjectionNext.app."
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: response),
                  let json = String(data: data, encoding: .utf8),
                  let stream = fdopen(forMode: "w") else {
                return
            }
            defer { fclose(stream) }
            (json + "\n").withCString {
                _ = fputs($0, stream)
            }
        }
    }
}
