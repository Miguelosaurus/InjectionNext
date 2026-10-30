# Swift Sim prepared delivery protocol

This is an additive development-only protocol for Swift Sim's private engine.
It does not enable execution while iOS suspends or terminates an application.
No background entitlement or public injection endpoint is added.

The client has one socket/command-reader owner. It retries with a capped
0.25–16 second backoff, pauses when the application enters the background, and
resumes on foreground execution. A network-path update invalidates only its
owned socket; the worker exits the old reader before connecting a replacement.
Root readiness is advertised only after SwiftSimLive subscribes to revision
notifications. A process-lifetime ledger prevents duplicate application or
refresh after a reconnect. Receipts are bounded to 1,024 requests and fail
closed at capacity instead of evicting a request into a second application.

## Negotiation and identity

The engine advertises `prepared_delivery_protocol: 1` through the existing
metrics command. Only then does a new client emit the additive metadata
response. Existing legacy injection commands retain their wire numbers.
An old engine does not acquire prepared-delivery capability from a new client.

Private `status` includes `prepared_delivery_protocol`, `engine_instance_nonce`,
`client_capabilities` and `client_identity`. Identity contains `bundle_id`,
`bundle_version`, `build_number`, loaded `executable_uuid`, `debug_dylib_uuid`,
`process_nonce`, `connection_nonce`, `is_active`, `root_ready` and `root_revision`.
The corrected SDK also advertises `replacement-proof-v2`; the helper can require
this capability before admitting an edit to avoid an old client's TI-only proof
failure. The existing prepared-delivery engine passes this client capability
through without requiring a new Mac engine binary or protocol downgrade.
The process nonce survives reconnects but changes on a new process launch.
These are fences reported by an authenticated private Debug client, not a new
public application-attestation service.

## Private Unix-socket actions

- `prepare_dylib`: a regular, singly linked, owner-only `.dylib` in the private
  `~/.swift-sim/live/queued-artifacts` root. Signs and validates it using the
  configured development identity, then returns `patch_digest` over the final
  signed bytes. Already valid bytes signed by that identity are not resigned.
  No connected application is required. An isolated candidate can select a
  different private root through its launch environment for tests.
- `inject_prepared`: `request_id` UUID, `attempt_id`, `patch_digest`, `path`,
  `expires_at_ms` (at most 24 hours), `baseline_revision`, and
  `expected_identity` containing the bundle/build, both UUIDs and process nonce.
  The engine captures the exact validated client, sends the exact signed bytes
  without resigning them, and returns `pending`. The native client verifies the
  digest and identity before loading; a new application also requires the
  expected revision, foreground execution and root readiness.
- `prepared_receipt`: `request_id` and `patch_digest` (or `digest`). Returns
  `unknown`, `pending`, `completed` or `rejected-no-effect` for the current
  process. A completed receipt includes the matching `report`. It never borrows
  the engine's unrelated last-injection result.

A report carries `request_id`, `patch_digest`, `client_identity`, `applied`,
`dynamic_replacements`, `refresh_acknowledged`, `refreshed` and `root_revision`.
A loaded dylib alone is not a successful managed patch: the replacement count
and observed root refresh are required. The native receipt is immutable once
accepted/completed; a retry of the same request/digest returns that result
without another load or refresh. New process launches have separate ledgers.

Replacement evidence recognizes both Swift `TI` implementation variables and
`TX` replacement variables and counts their common stem once. A linker may
dead-strip an unused `TI` while the active `TX` replacement still changes the
running function. Requiring `TI` alone incorrectly reported such edits as
unapplied even after the root revision advanced. A missing replacement or root
acknowledgement now has a specific report error code; neither is success.

The receipt ledger is process-local. This protocol does not cache executable
patches on the phone for offline startup. Durable desired source on the Mac can
be replayed by the helper after an authenticated matching Debug process
reconnects; the binary's original UI may appear before that replay. Offline
relaunch starts the installed binary, and iOS suspension grants no execution
time. No device-local cache or startup-frame suppression is claimed.

A narrow pre-admission race can return `admission: rejected-no-effect` with
`PREPARED_WAITING_FOR_FOREGROUND` or `PREPARED_BASELINE_MISMATCH`. It echoes
`attempt_id`; the engine accepts this disposition only for the latest attempt.
The same operation can then retry safely. Arbitrary `applied: false` failures,
partial mutations and ambiguous transport outcomes are not this disposition.

After an engine restart its receipt cache may be unknown while the app remains
alive. Resubmitting the **same** request/digest/identity lets the native ledger
replay its receipt. Do not substitute a new request or artifact to clear an
uncertain application. Expired and structurally incompatible work fails closed.
Interposition-only offline preparation is not introduced by this protocol.

## Local verification

```sh
SWIFT_SIM_DISABLE_CLIENT_AUTOCONNECT=1 swift test -j 2
bash NativeTests/run-reconnect-tests.sh
bash NativeTests/run-prepared-engine-tests.sh
```

The opt-out prevents a test executable from contacting an existing developer
engine. Socket-pair tests validate bounds before frame allocation, malformed
stream shutdown and normal UTF-8 reads. The native lifecycle harness exercises
one-reader ownership, disconnect, background/foreground and network wakeups.
The engine harness uses temporary Mach-O artifacts and validates final signed
digests, exact transmission, process/attempt fences and receipt behavior.
The SwiftPM replacement-evidence test compiles and loads actual stripped and
unstripped replacement dylibs, observes the function change, and verifies that
ordinary loaded code provides no replacement evidence. This reproduces the
TI-only reporting failure without relying on fabricated symbol names.
These fixtures do not establish physical iPhone acceptance.
