# Native replacement proof v3 — 2026-10-30

Status: implementation and host qualification complete; awaiting orchestrator
review, reviewed runtime pin/bootstrap, and physical-device qualification.
**No push, installed-engine replacement or phone activation was performed by
this workstream.** This file supersedes the earlier paused WIP checkpoint.

Workspace: `/Users/miguel/.codex/worktrees/swift-sim-client-reconnect/InjectionNext`.
The implementation starts from `d6a3abf82e94c255dc294ebb1bae168910c961c9`.
The previously installed product runtime remains independent of this commit.

## Scope and contract

`PreparedReplacementProof.swift` is shared by the engine and Debug SDK. The
SPM Release SDK excludes it under the same guard as the existing client.
The engine advertises `prepared_replacement_proof_protocol: 3`; the native
client advertises `replacement-proof-v3` alongside v2. Missing request proof
uses v2; malformed or unknown proof never silently downgrades.

```json
{
  "replacement_proof": {
    "version": 3,
    "swift_replacements": 6,
    "objc_callbacks": [{
      "class_name": "_TtC7Example11Coordinator",
      "selector": "scrollViewWillBeginDragging:",
      "replacement_selector": "__swiftSim_callback:",
      "type_encoding": "v24@0:8@16"
    }]
  }
}
```

Canonicalization uses sorted JSON object keys without escaped slashes and
callbacks sorted by class name plus NUL plus selector. Target/alias keys must
be globally unique, making later identity-field tie breakers immaterial.
Maximum 256 callbacks, 512 total replacements, canonical proof JSON at most
12,288 bytes; entire engine-to-client envelope at most 16,384 bytes.
Class names are bounded at 1,024 bytes, selectors at 256, encodings at 512.
Names/encodings are ASCII; selector identifiers use letters, numbers, `_`, `$`
and `:` separators, start with letter/underscore/dollar, and preserve colon
arity. Unknown keys, duplicate targets, alias overlaps and Boolean counts
reject. The helper's independent validator must stay aligned.

The executable Swift test verifies this cross-runtime canonical SHA-256 vector:
`a375fa459679b23c12fba308dc177f66bad83f9de4478d63fb248e431cbfafd5`.

V3 reports retain honest `dynamic_replacements` and add
`replacement_proof_version`, `coverage_digest`,
`expected_swift_replacements`, `objc_replacements`,
`represented_replacements`, `complete_replacement_coverage`,
`objc_callback_proofs` and `attempt_id`. Each callback proof echoes the four
identity fields and has `owns_selector`, `implementation_matches`,
`encoding_matches`, `implementation_in_patch`,
`previous_implementation_changed`, and `verified` booleans. No pointer values
or local image paths are emitted.

## Native evidence and admission

Before load, each original selector must belong directly to its exact class;
inherited/missing methods, wrong encoding and existing replacement aliases
reject. Each patch/restoration therefore needs fresh generation-specific aliases.
After load and root refresh, current original/alias IMPs must match, differ from
the captured original, have exact encodings, and belong to the exact loaded
image through `dladdr`. The apply gate remains held through final evaluation.

The runtime inventories every class and metaclass to detect extra patch-owned
instance methods or any patch-owned class method. A bounded parse of the
already-loaded Mach-O executable ranges filters irrelevant OS IMPs before
exact `dladdr` image-base checks. `PreparedProofPointer.h` uses the compiler's
`ptrauth_strip(..., ptrauth_key_function_pointer)` to normalize runtime IMPs
for introspection; no address-bit masks or calls through stripped pointers.
This follows [Clang pointer authentication](https://clang.llvm.org/docs/PointerAuthentication.html#ptrauth-strip)
and the installed toolchain header contract. Runtime Class arrays and `object_getClass`
use their raw C pointer ABI: Swift's imported `Any` bridging can send `+class`
or retain/release messages to runtime-only root classes and crash. Neither
pointer path sends messages or changes ownership. Inventory limits are 100,000
classes, 16,384 methods per class/metaclass, 2,000,000 methods total and a
cooperative two-second budget checked between classes. A single class scan
can extend beyond that budget; it is not a hard real-time deadline. Exceeding
a checked limit leaves coverage unproven, never fabricates success.

ObjC-only patches are accepted with zero Swift TX only when the exact nonempty
callback coverage is proven. Mixed patches require both exact counts. Every
post-load proof/load/refresh failure is uncertain, not retryable no-effect.
Identity changes at final publication also produce explicit uncertainty.

Native and engine receipt claims bind request, artifact digest, coverage,
attempt, baseline and five binary/process identity fields. The engine performs
check/claim/retry reset atomically: a concurrent fresh attempt cannot overwrite
an owner or enqueue a second write. Duplicate pending/completed requests return
the existing state. Only authenticated explicit pre-admission no-effect proof
with no uncertainty can reopen a claim for a fresh attempt. Root revision is a
strict integer and must advance beyond the admitted baseline for success.
Successful v3 receipts also require explicit `admission: "applied"`; a missing
or uncertain admission is rejected even if the other success flags are true.

## Reproducible host checks

```sh
swift test --scratch-path .build-feedback --filter 'PreparedDeliveryTests|PreparedPatchEvidenceTests|PreparedDeliveryFeedbackTests|PreparedReplacementProofTests|PreparedDeliveryV3Tests'
bash NativeTests/run-prepared-engine-tests.sh
bash NativeTests/run-prepared-release-exclusion.sh
bash NativeTests/run-prepared-pointer-tests.sh
git diff --check
```

- The targeted SDK suite passes **25 tests** (17 existing and 8 new).
- Existing SDK v2 ledger/feedback/real Swift TX evidence remains covered.
- New contract tests cover canonical digest, strict scalars, invalid versions,
  unknown fields, grammar, duplicate/overlap, empty coverage and byte limits.
- New real native test compiles a private nested Swift NSObject coordinator and
  five patch dylibs. Existing-object Objective-C dispatch changes 8 → 107 →
  207 → 307 → 407 → 8. Generation 1 proves ObjC-only with zero Swift TX; generation
  2 proves mixed coverage with one Swift TX. Generation 3's extra instance
  method and generation 4's extra class method make complete coverage false,
  even though their expected callback has changed. Generation 5 restores the
  original behavior through a fresh alias and proves its exact coverage. Wrong image/count, missing
  captures, stale aliases, inherited/missing selectors and ABI mismatch reject.
- Native ledger tests cover pending/cached coverage/attempt/baseline conflict,
  stale finishers, changed expected/fresh identities and Boolean revisions.
- Engine harness covers legacy behavior, v3 capability gating and wire relay,
  16 KiB envelope limit, tampered proof/identity/attempt/revision/count/success,
  cached conflicts, uncertain no-effect rejection and a 32-way fresh retry race
  with exactly one admitted owner and one write.
- The compiler pointer helper cross-compiles for iOS arm64 and arm64e;
  arm64e assembly explicitly contains `xpaci`. This is compile evidence,
  separate from execution on the physical device.
- Full SPM Release target builds. Actual object symbols contain no prepared
  proof/ledger runtime and no new callback/wire literals. DWARF source filenames
  are expected even for compiled-out files and are not runtime symbols.

Latest logs are `/tmp/swift-sim-native-v3-final-sdk-tests.log`,
`/tmp/swift-sim-native-v3-final-engine-tests.log`, and
`/tmp/swift-sim-native-v3-release.log`, and
`/tmp/swift-sim-native-v3-pointer.log`. Test fixtures remove their bounded
scratch directories; existing `.build-feedback/` stays untracked.

Initial failing runtime scans are retained in the macOS diagnostic reports
`xctest-2026-10-30-213652.ips` and `xctest-2026-10-30-213742.ips` under
`~/Library/Logs/DiagnosticReports/`. They exposed the Class-array cast and
object_getClass ownership bridges respectively. An interrupted slow scan was
sampled at `/tmp/swift-sim-v3-scan.sample`; executable-range filtering addressed
its global `dladdr` cost. Final fixture runtime including five compilations is
about six seconds on this host.

## Remaining qualification boundary

These are macOS ARM64 tests of actual native categories and production proof
code. They are not iPhone qualification, a blanket Swift/ObjC semantic
compatibility guarantee, or proof of arbitrary arm64e ABI support. No image is
unloaded and no runtime rollback is claimed; compensation uses a fresh patch.
External swizzlers cannot be globally serialized by this gate. Type encodings
alone do not establish semantic Swift signature/layout compatibility: helper
classification and exact no-load artifact preflight remain required.

The orchestrator owns independent review, helper integration, pinning the
reviewed SDK, signed Debug bootstrap and full mixed Swift/UIKit apply plus
restoration on the same phone process/binary with exact receipt and refresh
revision proof. Do not advertise full physical qualification before that gate.
