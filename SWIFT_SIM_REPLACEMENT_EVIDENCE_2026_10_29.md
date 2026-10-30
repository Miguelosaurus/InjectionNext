# Swift Sim replacement receipt correction — 2026-10-29

The Debug SDK previously required a loaded Swift symbol ending in `TI` before
reporting a managed replacement as applied. Swift emits a `TX` replacement
variable as well as a potentially unused `TI` implementation variable. Linker
dead stripping can remove the latter without removing the active replacement.

Read-only inspection of the three preserved Zenics test artifacts found zero
`TI` symbols and one `TX` definition in each. Miguel reported visibly seeing the
temporary label, while the helper journal retained no matching successful
proof. At investigation time the phone client was disconnected, so its original
native receipt could not be retrieved. The artifact and source evidence identify
a concrete false-negative reporting defect, not proof of the precise historical
receipt contents or the reason every prior connection ended.

The corrected SDK counts the union of `TI` and `TX` definitions by common
replacement stem. It still requires a loaded replacement and a separate root
refresh acknowledgement/increased revision. A plain loaded dylib provides no
replacement evidence. Missing replacement/refresh evidence receives a specific
error code instead of an undifferentiated negative report. The new client
capability is `replacement-proof-v2`, allowing a helper to reject the old SDK
before starting another application.

The old SDK can post a root refresh and advance its revision before its TI-only
test reports `applied: false`. Such an ambiguous application must not be blindly
retried in that same process. Recovery after a verified new matching process is
a separate helper responsibility; this native correction does not clear the
real journal, manufacture a receipt or alter process/binary/digest admission.

## Qualification

- `SWIFT_SIM_DISABLE_CLIENT_AUTOCONNECT=1 swift test --scratch-path .build-reconnect -j 2`:
  13 tests passed, including actual compiled and `dlopen`-loaded replacements.
- The stripped fixture visibly changes the called function from `1` to `2` with
  zero `TI` definitions. Corrected replacement evidence is one.
- An unstripped fixture contains both `TI` and `TX` but is counted once.
- An ordinary loaded Swift library has zero replacement evidence.
- `swift build --scratch-path .build-ios --triple arm64-apple-ios16.0 --sdk <installed iPhoneOS SDK> -j 2`:
  passed for the corrected Debug SDK.
- `SWIFT_SIM_DISABLE_CLIENT_AUTOCONNECT=1 swift build --scratch-path .build-reconnect -c release -j 2`:
  passed with the existing Release exclusion boundary.

The fixtures compile only disposable local code and disable client auto-connect.
They perform no phone install, connection mutation or live queue mutation. The
existing local 0.5.0 Mac engine protocol remains compatible; its binary does not
need rebuilding for this SDK-only correction. One new Debug app SDK bootstrap
is required before a physical test can exercise this fix. No physical-device
acceptance, offline executable cache or suppression of stale startup frames is
claimed by these results.
