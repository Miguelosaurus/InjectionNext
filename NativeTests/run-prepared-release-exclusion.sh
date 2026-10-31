#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${1:-$ROOT/.build-feedback}"
cd "$ROOT"
swift build --configuration release --scratch-path "$SCRATCH" --target InjectionBundle
python3 - "$SCRATCH" <<'PY'
import pathlib, subprocess, sys
scratch = pathlib.Path(sys.argv[1])
objects = list(scratch.glob('*/release/InjectionBundle.build/*.swift.o'))
assert objects, 'No actual Release SDK objects found'
for name in ['PreparedReplacementProof', 'PreparedDelivery', 'InjectionNext']:
    matches = [p for p in objects if p.name == name + '.swift.o']
    assert len(matches) == 1, f'Missing/ambiguous Release object: {name}'
    symbols = subprocess.check_output(['nm', '-j', str(matches[0])], text=True)
    literals = subprocess.check_output(['strings', str(matches[0])], text=True)
    for forbidden in ['PreparedReplacementProof', 'PreparedDeliveryLedger', 'SwiftSimPreparedIMPAddress']:
        assert forbidden not in symbols, f'Release includes active prepared symbol: {forbidden}'
    # DWARF contains source filenames even when the entire file is compiled out.
    for forbidden in ['replacement-proof-v3', 'PREPARED_OBJC_PREFLIGHT_FAILED', 'objc_callback_proofs']:
        assert forbidden not in literals, f'Release includes active prepared literal: {forbidden}'
print('Release SDK objects exclude native v3 proof, ledger, callback runtime and wire literals')
PY
