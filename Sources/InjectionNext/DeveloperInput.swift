#if DEBUG || !SWIFT_PACKAGE
import Foundation
import CoreGraphics
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Agent input for the developer's own Debug app: a tap or swipe in app-window
/// points, or text for the focused field. It runs only through the developer
/// tool path, after that path's identity, foreground and expiry checks.
enum DeveloperInput {
    case tap(CGPoint)
    case longpress(CGPoint)
    case swipe(from: CGPoint, to: CGPoint)
    case type(String)

    static let tools: Set<String> = ["tap", "longpress", "swipe", "type"]

    init?(tool: String, value: String?) {
        switch tool {
        case "tap":
            guard let p = Self.numbers(value, count: 2) else { return nil }
            self = .tap(CGPoint(x: p[0], y: p[1]))
        case "longpress":
            guard let p = Self.numbers(value, count: 2) else { return nil }
            self = .longpress(CGPoint(x: p[0], y: p[1]))
        case "swipe":
            guard let p = Self.numbers(value, count: 4) else { return nil }
            self = .swipe(from: CGPoint(x: p[0], y: p[1]), to: CGPoint(x: p[2], y: p[3]))
        case "type":
            guard let value, !value.isEmpty, value.count <= 512 else { return nil }
            self = .type(value)
        default:
            return nil
        }
    }

    static func valid(tool: String, value: String?) -> Bool { DeveloperInput(tool: tool, value: value) != nil }

    private static func numbers(_ value: String?, count: Int) -> [Double]? {
        guard let parts = value?.split(separator: ",", omittingEmptySubsequences: false), parts.count == count else { return nil }
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == count, numbers.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 20_000 }) else { return nil }
        return numbers
    }

    /// Touch phases as `(seconds from start, point, phase)` for the replay engine.
    var touches: [(Double, CGPoint, String)] {
        switch self {
        case .tap(let point):
            return [(0, point, "began"), (0.06, point, "ended")]
        case .longpress(let point):
            return [(0, point, "began"), (0.8, point, "ended")]
        case .swipe(let from, let to):
            let steps = 12, duration = 0.3
            var events: [(Double, CGPoint, String)] = [(0, from, "began")]
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                events.append((duration * t, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), "moved"))
            }
            events.append((duration + 0.016, to, "ended"))
            return events
        case .type:
            return []
        }
    }

    struct SettleState {
        static let pollInterval: TimeInterval = 0.05
        static let minimum: TimeInterval = 0.1
        static let timeout: TimeInterval = 1.5
        private(set) var consecutiveQuietPolls = 0

        mutating func shouldComplete(elapsed: TimeInterval, quiet: Bool) -> Bool {
            consecutiveQuietPolls = quiet ? consecutiveQuietPolls + 1 : 0
            return elapsed >= Self.timeout || (elapsed >= Self.minimum && consecutiveQuietPolls >= 2)
        }
    }

    #if canImport(UIKit) && !os(watchOS)
    /// Completes with nil on success or a typed error code.
    @MainActor func perform(in window: UIWindow, completion: @escaping (String?) -> Void) {
        switch self {
        case .tap(let point), .longpress(let point):
            guard window.bounds.contains(point) else { completion("DEVELOPER_INPUT_OUTSIDE_WINDOW"); return }
        case .swipe(let from, let to):
            guard window.bounds.contains(from), window.bounds.contains(to) else { completion("DEVELOPER_INPUT_OUTSIDE_WINDOW"); return }
        case .type(let text):
            guard let field = Self.firstResponder(in: window) as? UIKeyInput else { completion("DEVELOPER_INPUT_NO_FOCUSED_FIELD"); return }
            field.insertText(text)
            completion(nil)
            return
        }
        let payload = ["events": touches.map { ["time": $0.0, "touches": [["id": 1, "x": $0.1.x, "y": $0.1.y, "phase": $0.2, "tapCount": 1]]] }]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { completion("DEVELOPER_INPUT_INVALID"); return }
        json.withCString { InjectionReplayTouchEventsJSON($0) }
        // Start observing after the final scheduled phase.
        DispatchQueue.main.asyncAfter(deadline: .now() + (touches.last?.0 ?? 0)) {
            Self.waitForSettle(in: window, completion: completion)
        }
    }

    @MainActor private static func waitForSettle(in window: UIWindow, completion: @escaping (String?) -> Void) {
        let start = ProcessInfo.processInfo.systemUptime
        var state = SettleState()
        func poll() {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            if state.shouldComplete(elapsed: elapsed, quiet: isQuiet(window)) {
                completion(nil)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + SettleState.pollInterval) { poll() }
            }
        }
        poll()
    }

    @MainActor private static func isQuiet(_ window: UIWindow) -> Bool {
        let limit = 3000
        var layers = [window.layer]
        var visited = 0
        while let layer = layers.popLast() {
            visited += 1
            if visited > limit || layer.animationKeys()?.contains(where: { key in
                // Endless animations (cursor blink, spinners) never settle; ignore them.
                guard let animation = layer.animation(forKey: key) else { return false }
                return !(animation.repeatCount.isInfinite || animation.duration.isInfinite
                    || animation.repeatDuration.isInfinite || animation.duration > 60)
            }) == true { return false }
            if let children = layer.sublayers {
                if visited + layers.count + children.count > limit { return false }
                layers.append(contentsOf: children)
            }
        }
        var views: [UIView] = [window]
        visited = 0
        while let view = views.popLast() {
            visited += 1
            if visited > limit { return false }
            if let scroll = view as? UIScrollView, scroll.isDragging || scroll.isDecelerating { return false }
            let children = view.subviews
            if visited + views.count + children.count > limit { return false }
            views.append(contentsOf: children)
        }
        return true
    }

    @MainActor private static func firstResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        for subview in view.subviews { if let found = firstResponder(in: subview) { return found } }
        return nil
    }
    #endif
}
#endif
