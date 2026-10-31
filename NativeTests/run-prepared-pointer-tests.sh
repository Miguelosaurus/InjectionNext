#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/swift-sim-proof-pointer.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
cat > "$TEST_ROOT/probe.m" <<'SOURCE'
#include "PreparedProofPointer.h"
uintptr_t proofAddress(IMP value) { return SwiftSimPreparedIMPAddress(value); }
SOURCE
for ARCH in arm64 arm64e; do
  xcrun --sdk iphoneos clang -arch "$ARCH" -miphoneos-version-min=16.0 -O1 -S \
    -I "$ROOT/Sources/InjectionNextC/include" "$TEST_ROOT/probe.m" -o "$TEST_ROOT/$ARCH.s"
done
python3 - "$TEST_ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
arm64e = (root / 'arm64e.s').read_text()
assert re.search(r'\bxpaci\s+x\d+', arm64e), 'Compiler must strip instruction PAC in arm64e introspection helper'
print('iOS arm64 and arm64e pointer helper compile; arm64e emits compiler PAC stripping (not a bit mask)')
PY
