#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/swift-sim-developer-reports.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"
xcrun swiftc "$ROOT/App/InjectionNext/DeveloperReportStore.swift" \
  "$ROOT/NativeTests/DeveloperReportTests.swift" -o "$WORK/tests"
"$WORK/tests" "$WORK"
xcrun swiftc -D DEBUG "$ROOT/Sources/InjectionNext/DeveloperTools.swift" \
  "$ROOT/NativeTests/DeveloperToolTests.swift" -o "$WORK/tool-tests"
"$WORK/tool-tests"
