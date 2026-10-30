#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/swift-sim-registration-contract.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
xcrun swiftc -parse-as-library "$ROOT/App/InjectionNext/CompilationRegistration.swift" \
  "$ROOT/NativeTests/CompilationRegistrationTests.swift" -o "$TEST_ROOT/registration-tests"
"$TEST_ROOT/registration-tests"
