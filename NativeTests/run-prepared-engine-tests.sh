#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/swift-sim-engine-contract.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
printf 'int fixture(void) { return 7; }\n' > "$TEST_ROOT/fixture.c"
xcrun clang -dynamiclib "$TEST_ROOT/fixture.c" -o "$TEST_ROOT/fixture.dylib"
chmod 0600 "$TEST_ROOT/fixture.dylib"
xcrun swiftc -parse-as-library -import-objc-header "$ROOT/Sources/InjectionNextC/include/PreparedProofPointer.h" "$ROOT/Sources/InjectionNext/PreparedReplacementProof.swift" "$ROOT/App/InjectionNext/PreparedDeliveryEngine.swift" \
  "$ROOT/NativeTests/PreparedEngineTests.swift" -o "$TEST_ROOT/prepared-tests"
SWIFT_SIM_PREPARED_ROOT="$TEST_ROOT" "$TEST_ROOT/prepared-tests" "$TEST_ROOT"
