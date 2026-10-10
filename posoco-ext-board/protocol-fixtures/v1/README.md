# Board protocol v1 canonical fixtures

These are real JSON **server frames and client commands**, not UI models. The wire codec in
`src/protocol/codec.mbt`, full-entity projection in `src/protocol/projection.mbt`,
and composite bootstrap in `src/backend/bootstrap.mbt` define their shape.
Future SvelteKit 3 and desktop clients consume this contract; it is not a
Rabbita-specific contract and contains no framework state or fields.

## Canonical reducer chain

Read the files in this order. Start with `BoardReplica::empty()`.

| File | Wire cursor / revision | Expected outcome |
| --- | --- | --- |
| `snapshot.json` | `last_seq=2`, `board_revision=2` | `Applied` |
| `task-created.json` | `seq=1`, `board_revision=1` | `Duplicate` |
| `task-updated.json` | `seq=3`, `board_revision=3` | `Applied` |
| `attempt-started.json` | `seq=4`, `board_revision=4` | `Applied` |
| `attempt-finished.json` | `seq=5`, `board_revision=5` | `Applied` |
| `telemetry.json` | `seq=6`, `board_revision=0` | `Applied` (cursor only) |
| `command-result.json` | `current_revision=5`, no cursor | `CommandSettled` |
| `resync-required.json` | `current_seq=7` | `NeedsSnapshot` |
| `protocol-error.json` | no cursor / revision | `TerminalProtocolError` |

The populated snapshot represents two commits: creation of `task-1` at revision
1 / sequence 1, then queuing `attempt-1` at revision 2 / sequence 2. Its retained
suffix includes both Event frames and ends exactly at `last_seq`. The standalone
creation file is semantically identical to the first retained event. It is
**not** a new creation after the snapshot: it exercises duplicate delivery. An
independent test applies that same file after an authoritative empty revision-0,
sequence-0 snapshot, where it is `Applied`, then delivers it again as `Duplicate`.

Updates preserve task identity and creation time. Starting the queued discussion
attempt sets its start time; finishing preserves that time and sets the finish
time and succeeded status. All timestamps are nonnegative integer milliseconds.

## Wire and reducer invariants

- A snapshot is authoritative: `payload.board.revision` equals the envelope's
  `board_revision`. Its `tasks` and `attempts` are complete committed records.
  `payload.events` is retained transport history, **not** a second projection to
  replay over that board. A nonzero cursor requires a contiguous retained suffix
  ending at that cursor; an empty board baseline has cursor 0 and an empty suffix.
- Task/attempt records use snake_case fields and lowercase enum strings, with
  explicit JSON `null` for absent optional record fields. Board events carry the
  complete affected entity under `task` or `attempt`; metadata IDs agree with it.
  Event updates are entity upserts, not domain commands or optimistic patches.
- `seq` orders all events. `board_revision` tracks committed Board state. They
  are distinct counters, and numbers must be JavaScript-safe nonnegative integers.
  New events require the exact next sequence; duplicates do not change state.
  Board events require a snapshot baseline and the same or next board revision.
- Telemetry carries protocol-owned session/run/turn scope. Here its revision is
  deliberately stale (0): it advances the cursor to 6 without changing revision
  5, tasks, or attempts. Domain-projected events have `scope: null`.
- Command results settle the exact `command_id`; they never advance the cursor or
  project state, even when `current_revision` differs from the live baseline.
  This accepted result omits the optional `error`, as the codec does.
- Resync discards the baseline and projection. Its `current_seq` is a server head,
  not permission to advertise a snapshot or skip missing events. The next Hello
  must report `has_board_snapshot=false` and cursor 0 until a new snapshot arrives.
- The protocol error file is a valid `type: "error"` frame, not malformed JSON.
  The reducer reports its stable code (`hello_required`) as terminal; its message
  is not a reducer state update. Hosts stop/reconnect as appropriate.

## Canonical task and attempt command examples

These nine client frames are independent examples, not part of the server
reducer chain above:

| File | Name | Expected revision |
| --- | --- | --- |
| `task-create-command.json` | `board.task.create` | 0 |
| `task-update-command.json` | `board.task.update` | 1 |
| `task-set-dependencies-command.json` | `board.task.set_dependencies` | 2 |
| `task-move-command.json` | `board.task.move` | 2 |
| `attempt-queue-command.json` | `board.attempt.queue` | 2 |
| `attempt-start-command.json` | `board.attempt.start` | 3 |
| `attempt-finish-command.json` | `board.attempt.finish` | 4 |
| `review-approved-command.json` | `board.review.record` | 5 |
| `review-changes-requested-command.json` | `board.review.record` | 5 |

Create includes all six required args and explicit task identity. Update shows
all editable fields, including an empty `definition_of_done` array that clears
it; omitted update fields remain unchanged and are never encoded as `null`.
Set-dependencies replaces the complete dependency list with explicit task IDs; it
does not encode graph validity in the client. Move contains only `id` and `to`.
The three attempt commands form one independent queued→started→finished
progression for a second attempt: queue carries the explicit attempt ID, task ID
and kind; start carries only the attempt ID; finish carries the attempt ID plus
an explicit terminal outcome — the terminal choice is never omitted or defaulted.
The two review commands record one terminal decision on a third, independent
Review attempt: the args allowlist is exactly `id` and `decision`, and the
decision is one of `approved` or `changes_requested`.

`pending` is deliberately not a recordable decision. A review attempt is
implicitly `pending` while it runs, so `pending` appears only in attempt
records, never in a command. Timestamp authority stays with the server: the
`board.review.record` schema has no time field, and a client-sent `at_ms` is an
unknown field. The strict server decode rejects every deviation as
`invalid_arguments` — `decision: "pending"`, unknown decision strings, `null`,
extra fields and client timestamps — while the frame envelope itself stays
transport-valid.

Rabbita is one implementation of this client contract. SvelteKit 3 and Proton
hosts implement the same names, schemas, and fixtures using their own adapters,
not by importing or framing the standalone UI. `command_id` is correlation only,
not an idempotency key: do not automatically resend a mutation after disconnect,
conflict, timeout, or uncertain delivery. Reconcile using snapshots/events.

## Native validation

The separate `src/fixture_tests` package uses public protocol/client APIs,
domain values for decoder assertions, and native filesystem/environment test
helpers. Production client imports remain protocol/JSON only. Tests decode
server fixtures with `decode_server_frame`, check semantic-JSON round trips,
and reduce the chain through both `apply_frame` and `apply_text`. Command fixtures
are decoded with `decode_client_frame` and strict `decode_board_command`, compared
with the typed client builders, and checked against exact domain commands with
an injected server timestamp.

From the `posoco-ext-board` module directory:

```sh
moon check src/fixture_tests --target native --frozen --output-json
moon test src/fixture_tests --target native --frozen --output-json
moon fmt src/fixture_tests
moon fmt src/fixture_tests --check
```

The loader searches ancestors of the runtime working directory for the fixture
path at module, extension-workspace, Cetas-repository, or outer-repository level.
This works when Moon runs tests from a package or build directory; no absolute
machine path is compiled into the tests. For a runner outside the checkout, set
`POSOCO_BOARD_FIXTURES` to this `protocol-fixtures/v1` directory (relative to that
runner's working directory, or an externally supplied absolute path). The loader
accepts an injected environment source; tests exercise that seam without changing
process-global environment variables. An invalid override fails rather than
silently loading a different copy.
