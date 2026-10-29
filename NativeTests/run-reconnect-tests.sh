#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/swift-sim-native-reconnect.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
xcrun clang++ -fobjc-arc -DDEBUG=1 -DSWIFT_PACKAGE=1 -DINJECTION_RECONNECT_TESTING=1 \
  -I "$ROOT/Sources/InjectionNextC/include" -framework Foundation \
  "$ROOT/Sources/InjectionNextC/ClientBoot.mm" "$ROOT/Sources/InjectionNextC/SimpleSocket.mm" \
  "$ROOT/NativeTests/ClientReconnectTests.mm" "$ROOT/NativeTests/SocketFrameTests.mm" -o "$TEST_ROOT/reconnect-tests"
python3 - "$TEST_ROOT/reconnect-tests" <<'PYTEST'
import subprocess, sys
subprocess.run([sys.argv[1]], check=True, timeout=10)
PYTEST
