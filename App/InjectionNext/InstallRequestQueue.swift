import Foundation
import Darwin

/// Demand-driven install handoffs. Existing client metadata wakes queued work;
/// no timer, new socket, child process, or hot-reload queue dependency is added.
final class InstallRequestQueue {
    struct Entry: Codable, Equatable {
        let id: String
        let selector: [String: String]
        let value: String
        let expiresAt: Double
        var state: String
    }
    enum Availability { case waiting, unsupported, ready(() -> Bool?) }
    enum Failure: String, Error {
        case invalid = "INSTALL_REQUEST_INVALID", conflict = "INSTALL_REQUEST_CONFLICT"
        case unavailable = "INSTALL_QUEUE_UNAVAILABLE", capacity = "INSTALL_QUEUE_CAPACITY"
    }
    private let path: URL
    private let now: () -> Double
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "SwiftSimInstallHandoff", qos: .utility)
    private var entries: [Entry]
    private var scheduled = false
    private var wakeAgain = false
    private var usable = true
    var inspect: ((Entry) -> Availability)?

    init(path: URL, now: @escaping () -> Double = { Date().timeIntervalSince1970 }) throws {
        self.path = path; self.now = now
        try Self.privateParents(path.deletingLastPathComponent())
        entries = try Self.read(path) ?? []
        guard entries.count <= 32, Set(entries.map(\.id)).count == entries.count else { throw Failure.invalid }
        for entry in entries {
            guard UUID(uuidString: entry.id) != nil,
                  ["waiting", "opening", "prompt-requested", "unconfirmed", "rejected", "cancelled", "expired"].contains(entry.state),
                  entry.value.utf8.count <= 4096, entry.expiresAt.isFinite,
                  Self.validSelector(entry.selector) else { throw Failure.invalid }
        }
        // A process death around an OS handoff never grants replay permission.
        for index in entries.indices where entries[index].state == "opening" { entries[index].state = "unconfirmed" }
    }

    static func eligible(_ entry: Entry, identity: [String: Any], capabilities: [String], pendingReload: Bool) -> Bool {
        entry.selector.allSatisfy { key, value in
            guard let actual = identity[key] as? String else { return false }
            return key.hasSuffix("_uuid") ? actual.lowercased() == value.lowercased() : actual == value
        } && capabilities.contains("foreground-install-v1") && identity["is_active"] as? Bool == true
          && identity["root_ready"] as? Bool == true && !pendingReload
    }

    private static func validSelector(_ selector: [String: String]) -> Bool {
        let fields = ["bundle_id", "bundle_version", "build_number", "executable_uuid", "debug_dylib_uuid"]
        return selector.count == fields.count && fields.allSatisfy { key in
            guard let value = selector[key], !value.isEmpty, value.utf8.count <= 256 else { return false }
            return !key.hasSuffix("_uuid") || UUID(uuidString: value) != nil
        }
    }

    func enqueue(id: String, selector: [String: String], value: String) throws -> Entry {
        guard Self.validSelector(selector), let intent = DeveloperInstallIntent.parse(value,
                bundleID: selector["bundle_id"] ?? "", now: now()), intent.buildID.lowercased() == id,
              intent.build != selector["build_number"] else { throw Failure.invalid }
        lock.lock(); defer { lock.unlock() }
        guard usable else { throw Failure.unavailable }
        if let existing = entries.first(where: { $0.id == id }) {
            guard existing.selector == selector, existing.value == value else { throw Failure.conflict }
            return projected(existing)
        }
        guard !entries.contains(where: { $0.selector["bundle_id"] == selector["bundle_id"]
            && ["waiting", "opening", "unconfirmed"].contains($0.state) && $0.expiresAt > now() }) else { throw Failure.conflict }
        // Keep bounded tombstones beyond the two-hour URL lifetime.
        entries.removeAll { $0.expiresAt + 86400 < now() }
        guard entries.count < 32 else { throw Failure.capacity }
        let entry = Entry(id: id, selector: selector, value: value, expiresAt: intent.expiresAt, state: "waiting")
        entries.append(entry)
        try save()
        return entry
    }

    func status(_ id: String) throws -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard usable else { throw Failure.unavailable }
        return entries.first(where: { $0.id == id }).map(projected)
    }

    func cancel(_ id: String) throws -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard usable else { throw Failure.unavailable }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        if entries[index].state == "waiting" { entries[index].state = "cancelled"; try save() }
        return projected(entries[index])
    }

    private func projected(_ entry: Entry) -> Entry {
        var entry = entry
        if entry.state == "waiting" && entry.expiresAt <= now() { entry.state = "expired" }
        return entry
    }

    func wake() {
        lock.lock()
        guard usable, entries.contains(where: { $0.state == "waiting" && $0.expiresAt > now() }) else { lock.unlock(); return }
        if scheduled { wakeAgain = true; lock.unlock(); return }
        scheduled = true; lock.unlock()
        worker.async {
            repeat {
                self.lock.lock(); self.wakeAgain = false; self.lock.unlock()
                self.drain()
                self.lock.lock()
                if !self.wakeAgain { self.scheduled = false; self.lock.unlock(); return }
                self.lock.unlock()
            } while true
        }
    }

    // Exposed to the native tests; production runs only on the bounded worker.
    func drain() {
        lock.lock(); let pending = usable ? entries.filter { $0.state == "waiting" && $0.expiresAt > now() } : []; lock.unlock()
        for entry in pending {
            let available = inspect?(entry) ?? .waiting
            if case .waiting = available { continue }
            lock.lock()
            guard usable, let index = entries.firstIndex(where: { $0.id == entry.id }),
                  entries[index].state == "waiting", entries[index].expiresAt > now() else { lock.unlock(); continue }
            if case .unsupported = available {
                entries[index].state = "rejected"
                try? save(); lock.unlock(); continue
            }
            // Persist BEFORE sending. Neither reconnect nor engine restart may
            // repeat a request after the outcome becomes uncertain.
            entries[index].state = "opening"
            do { try save() } catch { lock.unlock(); return }
            lock.unlock()
            guard case let .ready(send) = available else { continue }
            let result = send()
            lock.lock()
            guard let completedIndex = entries.firstIndex(where: { $0.id == entry.id }) else { lock.unlock(); return }
            entries[completedIndex].state = result == true ? "prompt-requested" : result == false ? "rejected" : "unconfirmed"
            try? save()
            lock.unlock()
        }
    }

    private func save() throws {
        do {
            try Self.privateParents(path.deletingLastPathComponent())
            let data = try JSONEncoder().encode(entries)
            let temporary = path.deletingLastPathComponent().appendingPathComponent(".install-" + UUID().uuidString)
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.unavailable }
            defer { unlink(temporary.path) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
            guard rename(temporary.path, path.path) == 0 else { throw Failure.unavailable }
            let directory = open(path.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directory >= 0 else { throw Failure.unavailable }
            defer { close(directory) }
            guard fsync(directory) == 0 else { throw Failure.unavailable }
        } catch { usable = false; throw Failure.unavailable }
    }

    private static func privateParents(_ directory: URL) throws {
        var current = directory
        while current.path != "/" {
            var value = stat()
            guard lstat(current.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw Failure.unavailable }
            if current == directory {
                guard value.st_uid == getuid(), value.st_mode & 0o077 == 0 else { throw Failure.unavailable }
            }
            current.deleteLastPathComponent()
        }
    }

    private static func read(_ path: URL) throws -> [Entry]? {
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw Failure.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_uid == getuid(), value.st_nlink == 1, value.st_mode & 0o077 == 0,
              value.st_size > 0, value.st_size <= 196608,
              let data = try handle.read(upToCount: 196609), data.count == value.st_size else { throw Failure.unavailable }
        return try JSONDecoder().decode([Entry].self, from: data)
    }
}
