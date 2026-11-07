#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/swift-sim-install-request.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"
xcrun swiftc -D DEBUG "$ROOT/Sources/InjectionNext/DeveloperInstallIntent.swift" "$ROOT/App/InjectionNext/InstallRequestQueue.swift" "$ROOT/NativeTests/InstallRequestTests.swift" -o "$WORK/tests"
"$WORK/tests" "$WORK"
