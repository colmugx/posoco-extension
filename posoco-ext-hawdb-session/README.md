# posoco-ext-hawdb-session

Native HawDB implementation of Posoco SessionPort.

## Storage

The database owns two tables:

- posoco_hawdb_sessions: session id, metadata JSON, next message sequence.
- posoco_hawdb_messages: session id, sequence, and canonical message JSON.

Every checkpoint appends only new message rows and atomically updates session metadata and sequence. save replaces a session, truncate deletes message rows at and after the specified index, and load verifies the contiguous message sequence under a read transaction. SessionCheckpoint.from_index is an Agent cursor; the storage sequence is independent.

HawDB session data is not a JSONL document. The package does not import posoco-ext-fs-session, read fs-session files, or implement format migration.

## Development

The native integration workflow uses current colmugx/posoco main and nowledge-co/hawdb main. Maintainer CI builds the HawDB Rust adapter and runs MoonBit tests on Linux, macOS, and Windows.

A published MoonBit package must supply verified precompiled native binaries without requiring consumers to install Rust.

## Production gates

- Multiwriter revision checks and retry idempotency.
- Process crash/restart and transaction failure injection.
- Agent integration, replay, compaction and SessionCatalog.
- Independent Mooncakes consumer without Rust.
- Native distribution, provenance, licenses, and lifecycle/GC qualification.

This implementation is not approved for production.
