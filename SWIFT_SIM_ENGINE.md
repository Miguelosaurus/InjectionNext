# Swift Sim engine branch

The `swift-sim-engine` branch is a deliberately small integration layer over
InjectionNext. It keeps the normal standalone app behavior intact and adds an
environment-selected, headless mode for Swift Sim.

Swift Sim launches the executable with:

- `SWIFT_SIM_ENGINE=1`
- `SWIFT_SIM_ENGINE_SOCKET=/absolute/path/to/engine.sock`
- `SWIFT_SIM_PROJECT_ROOT=/absolute/path/to/project/root`
- `SWIFT_SIM_CODESIGN_IDENTITY=<development identity SHA-1>`

Engine mode suppresses windows, menu-bar UI, modal alerts, Xcode auto-launch,
and the legacy TCP control service. It automatically enables the device patch
server, watches the supplied project root, and exposes the existing JSON
control API through the supplied user-only Unix socket.

Swift Sim can register the exact `swift-frontend` commands emitted by its
baseline `xcodebuild` result bundle through the `register_compilations` control
action. This avoids patching Xcode's toolchain and makes command-line device
builds first-class inputs to subsequent file-watcher injections.
Swift Sim can request a specific watched source through `inject_source` and
correlate the request with an explicit success or failure result. File watching
remains available, but agent-driven edits do not depend on FSEvents timing.
Engine connections are treated as remote even when a userspace Tailnet proxy
presents the peer as loopback, ensuring patches are streamed to the device
instead of linked against its sandbox path.

## Staying current with upstream

`main` is reserved as a mirror of `johnno1962/InjectionNext`. Updates are
merged into `swift-sim-engine`, the engine is rebuilt, and Swift Sim's pinned
engine/client revisions are advanced together. Keeping the integration changes
isolated makes upstream bug fixes and protocol improvements straightforward to
adopt without exposing InjectionNext setup to Swift Sim users.
