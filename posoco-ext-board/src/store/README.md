# S3B1 snapshot store

This package is standalone. It does not change coordinator commits, restore
`BoardState`, publish to EventHub, accept WebSocket mutations, or execute Agents.
Callers must serialize writes and provide recovery time explicitly.

## Boundary

`BoardStore` has only asynchronous `load()` and `persist(snapshot, events)`.
`load()` returns `BoardLoad { snapshot: @domain.BoardStateSnapshot, journal:
Array[JournalRecord] }`. `persist` accepts that same domain snapshot plus typed
domain events; every appended record is tagged with schema version 1 and the
supplied snapshot revision, without allocating another revision. Empty event
arrays replace the snapshot without discarding the existing journal. Both stores
expose the complete detached journal on load, including records ahead of the
snapshot after a failed native rename. There is no separate memory-only audit API.
`MemoryBoardStore` works on native and JS; `FileBoardStore` is native-only and
uses `<root>/.cetas/board/default`, with `root="."` by default. An empty root is
also treated as `"."`, keeping the path relative to the current workspace.
Inject a workspace root using `FileBoardStore::FileBoardStore(root=...)`, not a
board directory.
Both detach requests and results, including task DoD/dependency arrays and `DependenciesSet` payloads.
Journal records and their nested event payloads are detached too.

There are no store-owned task/attempt/snapshot duplicates. Codecs reconstruct
`@domain.BoardTask` and `@domain.Attempt` through narrowly scoped public
`from_record(...)` factories, and return `@domain.BoardStateSnapshot` directly.
The factories preserve every field verbatim and copy nested arrays; they are
record constructors, not domain transitions or committed-state restoration.
`BoardTask::copy_detached`, `Attempt::copy_detached`, and
`BoardStateSnapshot::copy_detached` support detached copies. Storage codecs
validate these records. The committed `BoardState` remains encapsulated;
coordinator restoration/integration is not part of S3B1.

## Schema v1

`board.json` is one JSON object with exactly `schema_version: 1`, `revision`,
`tasks`, and `attempts`. Tasks contain all ten domain fields; attempts contain
all nine. All fields, including nullable fields, are required. Enum values are
explicit case-sensitive strings, not Debug representations. Every revision
and timestamp is a canonical **nonnegative decimal string**, from `"0"` through
`"9223372036854775807"`, preserving Int64 precision on JS. Nullable timestamps
and reviews use JSON `null`.

Each journal record is a JSON object with `schema_version: 1`, `revision`, `type`,
and every field of its typed domain event variant. `revision` uses the same
canonical nonnegative Int64 string encoding as snapshot revisions. All eight
domain event variants are encoded.
The journal has no replay semantics or separate sequence/revision allocator.

Decoders reject invalid JSON, duplicate keys (including escaped equivalents),
missing/unknown fields, wrong types, unknown enums/versions, empty identifiers,
empty titles/DoD items, and malformed/negative/out-of-range integers. Full
snapshots also reject duplicate task/attempt ids, missing attempt tasks, and
missing/self/duplicate/cyclic dependencies. Codecs validate storage structure
and references, not command FSM transitions, timestamp monotonicity, or S4
execution coupling. The domain already accepts explicit nonmonotonic times.

Every complete physical JSONL line must decode as a schema-v1 journal record.
Empty lines are errors. Only a **syntactically malformed JSON** final
*unterminated* physical line is ignored; a valid unterminated record is retained. Syntactically valid JSON with
invalid/missing/unknown schema fields, duplicate keys, or unknown events is an
error even in the final unterminated line. Before a future append, the native
store
truncates ignored residue to the validated prefix, or adds a separating newline
to a retained unterminated record. Invalid UTF-8 in complete lines is an error;
torn UTF-8 in the unterminated tail is handled as residue. This prevents an
ignored tail from corrupting the next append. No audit records are ever applied
to the authoritative snapshot.

## Native persistence

After validation/encoding, cancellation-shielded persistence creates the
directory recursively and performs:

1. Write `board.json.tmp` in the same directory.
2. Explicitly fsync the temp file.
3. Repair trailing audit residue if necessary; append event JSONL records.
4. Explicitly fsync the journal.
5. Atomically replace `board.json` using replace-rename.
6. Fsync the board directory and its ancestor chain (through cwd for relative
   paths, or root for absolute paths). Ancestors may have been created by a
   previous failed write, so retries must sync them too.

The installed `moonbitlang/async@0.22.4` file API supplies explicit `File::sync`,
append-open, and replace-rename; the POSIX implementation uses fsync and native
replace-rename syscalls. Directory open/fsync also works through that API. The
only C seam is descriptor-based `ftruncate` for audit tail repair (retries EINTR,
returns errno, borrows no MoonBit objects). No dependencies are added.

The six optional injected stages are `TempWrite`, `TempFsync`, `JournalAppend`,
`JournalFsync`, `Rename`, and `DirectoryFsync`, each failing immediately before
that operation. Failures before rename leave the previous authoritative board
unchanged, although the journal may be ahead. Filesystem-operation failures
perform cancellation-shielded, best-effort temp cleanup without masking the primary error; a cleanup failure
can leave residue. Temp residue is never loaded or promoted. Validation failures
before filesystem access do not change files. A missing board loads empty
revision 0; a corrupt board errors even when a valid temp exists. Audit corruption also errors, never
repairs the board. Missing directories are not created by load.

## Recovery

`recover_snapshot(snapshot, at_ms=...)` is pure and detached: all Running tasks
become Suspended with an updated timestamp and cleared ready timestamp; all
Running attempts become Interrupted with finished/updated timestamps while
preserving start time and review. It returns an explicit `changed` boolean plus
typed stage-change/attempt-finish events, in task order followed by attempt order. The revision increases exactly
once if anything changed, otherwise not at all. Negative time and revision
overflow are errors.

`load_recover_persist(store, at_ms=...)` loads, normalizes, and persists any
changes before returning them. Errors are returned without speculative success.
A second restart after successful normalization is a no-op: no revision bump,
new timestamps, extra audit records, or write. Returned recovery events are
facts for the caller, not authoritative EventHub publications.

## Durability limitations

- This is a single-writer store, not an optimistic-concurrency or cross-process
  transaction manager. Shared directories and concurrent writers are unsupported.
  The fixed temp filename depends on that contract.
- Rename is the visibility boundary. A directory-fsync failure occurs *after*
  replacement: the new snapshot may already be visible, but crash durability is
  uncertain. These failures (injected or real, including ancestor fsync errors)
  return `DurabilityUncertain(...)`, not a pre-rename `Io`/`Injected` error.
  An error is not proof of rollback; reload authoritative state before
  deciding what to do. No compensating rename is attempted.
- Board and audit are not one atomic transaction. A failed/aborted pre-rename write
  may leave extra complete audit records, and retries can duplicate audit facts.
  The journal is audit only, never a recovery log.
- Guarantees rely on filesystem/OS fsync and same-directory atomic replacement.
  Real power loss, storage hardware caches, network filesystems, and hostile
  external file replacement are not simulated by deterministic injection tests.
  macOS uses ordinary fsync, not F_FULLFSYNC.
- Native filesystem behavior is tested on macOS; the C tail-repair seam supports
  macOS/Linux. No Windows durability guarantee is made (unsupported platforms
  return ENOSYS for tail truncation). JS has the memory/codec/recovery implementation,
  not a filesystem implementation.
- The audit is validated/read in full on load and persist. There is no rotation,
  compaction, checksum, locking, size limit, backup, or automatic corrupt-board repair.
  Committed-state/coordinator restoration and the persistence commit barrier are deferred.

## Validation scope

The tests cover all domain fields/enums, exact Int64 values above JS's safe
integer range and at Int64 max, strict schema errors, detached public domain
snapshot roundtrips, matching memory/file journal results, safe tail repair,
and recovery idempotence. Six deterministic pre-operation failure stages pin
the visibility boundary and temp cleanup; a real IO/cleanup-failure test pins
primary-error preservation. They do not simulate physical power loss.
