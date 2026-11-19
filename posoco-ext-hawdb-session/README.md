# posoco-ext-hawdb-session (native development module)

This is a staged, non-production Posoco SessionPort on the upstream HawDB
MoonBit native adapter. It is not a published extension yet.

## Current design

B0/B2 stores one lossless canonical JSONL base snapshot per session. B3 adds
`posoco_session_delta_heads` and `posoco_session_delta_rows`: a checkpoint
atomically appends only new canonical message envelopes and optionally replaces
metadata in a small head row, leaving historical snapshot bytes untouched.
`load` reconstructs ordered messages with strict contiguous-sequence checks.
`save` still atomically replaces the base and clears the incremental journal;
`truncate` removes only journal tail rows unless it must cut into a legacy base.
Posoco's `from_index` is a logical caller cursor and is never reused as a SQL
sequence or physical row count.

## Build and integration contract

The integration workflow follows the current `nowledge-co/hawdb` main source
without selecting an engine release or freezing MoonBit/Rust versions. It builds
HawDB's own `bindings/moonbit/native` adapter, checks Rust lifetime/rollback
tests, configures the actual platform archive path, and runs native Posoco
SessionStore tests on Linux, macOS and Windows.

Local development uses the same source layout:

1. Check out upstream HawDB main under `_hawdb_checkout`.
2. Install MoonBit and a Rust toolchain (these are **maintainer** requirements,
   not requirements we may impose on published MoonBit consumers).
3. Run `python3 posoco-ext-hawdb-session/tools/assemble_workspace.py`, then
   `moon update`, then `moon check --target native posoco-ext-hawdb-session`.
4. Run `cargo test --release --lib` and `cargo build --release` inside
   `_hawdb_checkout/bindings/moonbit/native`.
5. Run `python3 posoco-ext-hawdb-session/tools/configure_native_link.py`,
   then `moon test --target native posoco-ext-hawdb-session`.

The linker helper resolves the built archive to an absolute path. It is a
temporary integration-workspace mechanism; it must not be part of an eventual
Mooncakes consumer's experience. External consumers must obtain validated
prebuilt native assets, without installing Rust or cloning HawDB.

## Open production gates

- B3 incremental-message verification beyond the current smoke suite: multi-session
  isolation, full crash/reopen, performance bounds, overflow, malformed head,
  and transactional failure injection.
- Revision conflicts, retry/idempotency, and multiple writers/processes.
  The current B3 append path is **not yet retry-idempotent** after an ambiguous
  commit outcome and must not be exposed to concurrent writers.
- Crash injection and recovery across process restart.
- Full fs-session compatibility, SessionCatalog and Agent replay/recovery.
- Independent MoonBit consumer, GC/finalizer, failure injection and stress.
- Reproducible **evidence** of each tested toolchain/source combination,
  licensing, provenance and a published native distribution.

No production claim until these gates pass.
