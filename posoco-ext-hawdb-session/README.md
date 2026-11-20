# posoco-ext-hawdb-session

Native HawDB implementation of Posoco SessionPort.

## Storage

The database owns three tables:

- posoco_hawdb_sessions: session id, metadata JSON, next message sequence, revision.
- posoco_hawdb_messages: session id, sequence, and canonical message JSON.
- posoco_hawdb_operations: guarded checkpoint receipts.

Every checkpoint appends only new message rows and atomically updates session metadata and sequence. save replaces a session, truncate deletes message rows at and after the specified index, and load verifies the contiguous message sequence under a read transaction. SessionCheckpoint.from_index is an Agent cursor; the storage sequence is independent.

HawDB session data is not a JSONL document. The package does not import posoco-ext-fs-session, read fs-session files, or implement format migration.

## Session management

The store implements Posoco `SessionPort`, `Extension`, and `CommandPort`.
It contributes a session capability and a `/name` command to Agent composition.

The native `list_ids`, `summary`, `set_session_name`, and `check_id`
methods support session discovery, display titles, renaming, and session ID
validation. `open(path, cwd=Some(project_dir))` records the normalized project
directory on session writes. Model selection fields passed in session metadata
are retained.

## Guarded checkpoints

The native extension offers `revision(session_id)` and
`checkpoint_guarded(session_id, expected_revision, operation_id, checkpoint)`.
A guarded checkpoint rejects stale revisions. A repeated operation ID with
the same expected revision and canonical payload returns its original receipt
without appending again. Reusing an operation ID with a different payload
fails. A no-op checkpoint can also be retried.

The SessionPort checkpoint method remains available without a revision
precondition. Consumers requiring concurrency control must use the guarded
method and test ownership and transaction conflicts in their host.

## Development

The native integration workflow uses current colmugx/posoco main and nowledge-co/hawdb main. Maintainer CI builds the HawDB Rust adapter and runs MoonBit tests on Linux, macOS, and Windows.

A published MoonBit package must supply verified precompiled native binaries without requiring consumers to install Rust.

## Production gates

- Multi-process competing writer tests, unknown-commit recovery, and receipt retention policy.
- Process crash/restart and transaction failure injection.
- Host selection of HawDB, SessionCatalog wiring, streaming rewind, and full Agent replay/compaction tests.
- Model-selection event capture and session status announcements.
- Independent Mooncakes consumer without Rust.
- Native distribution, provenance, licenses, and lifecycle/GC qualification.

This implementation is not approved for production.
