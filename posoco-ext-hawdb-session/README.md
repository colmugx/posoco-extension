# posoco-ext-hawdb-session (native development module)

This is a staged, non-production Posoco SessionStore on the upstream HawDB
MoonBit native adapter. It is not a published extension yet.

## Current design

B0/B2 stores one lossless canonical JSONL document per session. Checkpoint
messages and optional metadata changes are committed in the same HawDB write
transaction. Posoco's from_index is a logical caller cursor and is not
misinterpreted as a physical row offset.

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

- B3 incremental ordered message storage, avoiding whole-document rewrites.
- Revision conflicts, retry/idempotency, and multiple writers/processes.
- Crash injection and recovery across process restart.
- Full fs-session compatibility, SessionCatalog and Agent replay/recovery.
- Independent MoonBit consumer, GC/finalizer, failure injection and stress.
- Reproducible **evidence** of each tested toolchain/source combination,
  licensing, provenance and a published native distribution.

No production claim until these gates pass.
