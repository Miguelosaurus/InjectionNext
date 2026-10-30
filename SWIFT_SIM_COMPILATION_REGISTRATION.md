# Swift Sim transactional compiler-map registration

The managed Mac engine advertises `compilation_registration_protocol: 1`.
Legacy `register_compilations` is rejected in managed engine mode. The previous
RPC wrote and compressed the entire platform cache after every frontend
command, and its caller imposed a five-second timeout for each command.
The preserved failed capture contains 89 commands and 856 source inputs;
its largest individual request is about 34 KiB, below the old framing limit.
A timeout alone does not establish which internal operation was slow.

The new private RPC accepts one complete bounded frontend map and returns a
queryable asynchronous receipt. It parses every command before entering the
commit barrier, then publishes every platform in one owner-private atomic
snapshot. In-memory compiler maps are updated on the compiler owner queue.
Registration never calls the legacy `store` pending-source injection hook.
This is metadata registration, not a native application retry.

## Protocol

`compilation_registration_status` without an identity returns the engine nonce,
activation generation and optional current/pending operation bindings.
`register_compilation_map` accepts:

- UUID `registration_id`;
- exact `expected_engine_nonce`;
- SHA256 `map_digest` of the literal UTF-8 `payload_json` string;
- SHA256 `provenance_digest` binding the helper-qualified signed binary,
  result log, source fingerprints and project/package inputs;
- `payload_json` containing up to 1,024 frontend command objects, no more than
  4 MiB before envelope escaping;
- matching `command_count` and an admission expiry within 180 seconds.

The control frame is bounded to 8 MiB. Each command has a bounded argument
array and working directory. One metadata operation may be pending/committing.
A matching duplicate returns its receipt; a conflicting identity or overlapping
map fails closed. Receipts are bounded to 128 operations per engine generation.

States are `scheduled`, `committing`, `committed`, `cancelled`, `failed`,
`superseded` and `unknown`. Only a current `committed` receipt may qualify the
helper manifest. Receipts include the request/digests, engine nonce, command and
registered counts, sources and current registration identity. A completed
receipt remains queryable after admission expiry. An expired staged map cannot
cross the commit barrier. Once commit begins, a late caller queries the same
operation rather than treating its missing reply as success or scheduling a
second map.

Each NEW admitted activation advances the generation, including later failures
or cancellations. A capture already pending/current reuses that operation.
Sequential A → B → A requires a new A activation; historical A receipts do not
qualify B's current compiler map. The helper rechecks the active receipt and
unchanged provenance before atomically publishing its local manifest.

The durable aggregate snapshot lives in the user's private Swift Sim runtime
directory. Existing symlinks, broad permissions, non-owner files and hardlinks
are rejected. Atomic rename publishes all platforms together, followed by
file/directory synchronization. No per-platform partial map is accepted as
compiler readiness. Managed cache reads prefer this complete aggregate.

## Control socket reliability

Control reads and writes use absolute deadlines, bounded frame/response sizes
and complete partial-write loops. Responses use `MSG_NOSIGNAL`. On Darwin,
setting `SO_NOSIGPIPE` only after a peer closes can return `EINVAL`; a late send
can otherwise terminate the engine with SIGPIPE. The regression reproduces the
closed-peer behavior against the actual transport implementation. This
qualifies a concrete defect, not the exact historical cause of the preserved
build's five-second timeout.

## Qualification

`NativeTests/run-compilation-registration-tests.sh` compiles the actual registry,
private snapshot store and socket transport. It checks large maps, pending
idempotence, no overlapping late operation, expiry, wrong engine/digest,
A → B → A activation, failed-attempt retry, atomic multi-platform/private
publication, unsafe links, closed peers, backpressure and absolute read/write
deadlines. The full Mac engine build also passes.

Only the Mac engine changes. The corrected Debug SDK at immutable revision
`a3341b6a861dde031334813db49f7c7111108c4a` remains compatible. The local 0.5.1
engine candidate is ad-hoc signed and strictly verified for this Mac's explicit
qualification; it is not a public binary or Developer ID release. No app build,
phone installation, live patch, real queue clear or target source change was
performed by this engine qualification.
