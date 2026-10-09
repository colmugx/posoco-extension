# posoco-ext-board-web

A Rabbita standalone browser shell for the Board wire contract. The shell is
read-only until it holds an authoritative snapshot; it then gains the v1
mutation surface: a New task editor, Edit cards, per-card Move controls,
and dependency editing in the task inspector. Attempt controls, review controls
and drag-and-drop remain out of scope.

- **Rabbita 0.16.4** owns rendering, named WebSocket commands, and delayed commands.
- **Board client** owns the authoritative replica; no second task/attempt projection lives in the UI model.
- **Warren 0.4.4** is a development/build tool, not a runtime dependency.
- **async 0.22.4** remains unchanged.

## Build

From the extension workspace:

```bash
moon install moonbit-community/warren@0.4.4
warren -C posoco-ext-board-web build --browser-entry cmd/browser --server-entry ""
```

This browser-only command produces `dist/index.html`, `dist/index.js`, and `dist/board.css`. Build output is ignored, not committed. No server entry is included.

For a scaffold preview:

```bash
warren -C posoco-ext-board-web dev --browser-entry cmd/browser --server-entry ""
```

Without a Board instance token the shell stays Offline. A live connection requires serving these assets from a Board-capable host on the same origin with `/?token=<instance-token>`. The preview is not a cross-origin proxy or an alternate Board backend.

### Embedded-asset regen workflow

The standalone native host embeds these Warren-built assets as its product page; consumers of that host need no Warren, no Node and no `dist/` checkout. Regeneration is always the Warren 0.4.4 build above followed by the native embed generator:

```bash
moon -C posoco-ext-board-native run tools/embed-assets/generate.mbtx --target native --output-json
moon -C posoco-ext-board-native run tools/embed-assets/generate.mbtx --target native --output-json -- --check
```

Commit the generated `posoco-ext-board-native/src/web_assets.generated.mbt`, not `dist/`. MoonBack serves these bytes directly from memory; its static resources do not contain the instance token. The root page remains token-gated, while actual manifest subresources are public behind the exact Host gate. The handwritten diagnostics page has been removed. See the native module README for generator regression checks.

## Contract

The app reads protocol, host, and query parameters from the current location. A minimal JS FFI helper supplies the location access missing from Rabbita and uses browser URL parsing; WebSocket operations themselves use Rabbita's `connect`, `send`, and `close`, with connection ID `board`.

`http:` maps to `ws:`, `https:` to `wss:`, always at the same host and `/ws`. Tokens are never written to local/session storage, rendered, or logged. Transport failure details and protocol messages are not displayed.

A fresh document starts with an empty replica. Opened sockets send the replica's Hello; only authoritative snapshots and full-entity Board events alter the projection. Unknown telemetry advances only the stream cursor. Gaps, inconsistent entities, unknown Board events and resync requests close the socket and reconnect for a snapshot. Protocol errors stop automatic retries.

Retries use Rabbita delayed commands: 250ms, 500ms, 1s, 2s, 4s, 8s, then a 10s cap. A valid snapshot resets the delay. One pending retry and connection-generation checks prevent duplicate schedules and stale socket callbacks from changing the current connection. Updates clone the replica before applying frames so incremental rendering never compares a mutated previous model.

## Mutations (v1)

Submission requires the connection to be Online, the replica to hold an authoritative snapshot, and no command in flight. Task creation and editing additionally require a trimmed non-empty title. The expected revision is read live at submit. Identifiers come from an injected UUID seam: the browser entry uses `crypto.randomUUID` and treats a missing or throwing API as a rejection — there is never a weak fallback. Command ids are `cmd-<uuid>` and task ids `task-<uuid>`; neither embeds tokens.

The single pending record stores correlation only: command id, mutation kind and expected revision. The command payload is never retained, so nothing can be replayed or resent; a reconnect socket sends only Hello. Every send failure callback correlates both the connection generation and the command id, so a late callback can never clear a newer pending command.

Command results never project replica state. An accepted correlated result clears the pending record, closes the matching editor and reports success. Any reported `current_revision` other than the replica's own revision — including on accepted results — marks the baseline stale: the replica is emptied and the existing bounded reconnect fetches a fresh snapshot. Rejections keep the draft, never roll back and never retry: a `revision_conflict` (or a stale reported revision) forces the same snapshot resync, `durability_uncertain` retains the event state only when the reported revision still matches, and `persistence_failed` at the same revision keeps the baseline. Disconnects and send failures with a command in flight clear the pending record, empty the replica, keep drafts and reuse the reconnect scheduler; ordinary disconnects preserve the baseline for replay.

A disconnected edit draft whose task disappears from a later authoritative snapshot closes with a notice. Drafts are never closed merely because reconciliation emptied the baseline: without a snapshot the board is unknown, and the draft survives until authoritative state returns.

Move suggestions mirror the Board v1 stage FSM — Created→Refining/Suspended, Refining→Ready/Suspended, Ready→Running/Refining/Suspended, Running→Review/Suspended, Review→Done/Ready/Refining/Suspended, Done→Refining, Suspended→Created/Refining/Ready. They are a UX convenience only; the durable server stays authoritative and may still reject a move. Definition-of-done drafts split one entry per line, dropping blank lines; entries rejoin with newlines when a draft is prefilled.

Every mutation control shares one disabled state: the shell accepts input only while the replica is authoritative, the connection is online and no command is in flight. Controls are semantic HTML with explicit label associations, explicit button types, and a live notice region that renders mapped safe text only — wire codes, store and protocol details never reach the UI.

## Task inspector and dependencies

Activate a card's title to inspect it. Selection stores only its task ID; every render resolves the task and its read-only attempt history from the current replica. The responsive panel shows description, stage, priority, definition of done, dependency titles and IDs, and the available task/attempt timestamps in UTC. Close clears selection. Baseline invalidation hides entity details without losing selection; a subsequent authoritative snapshot revalidates it and closes a missing task with a safe notice.

Edit dependencies opens independent copies of the current relationship IDs. Labeled checkboxes exclude the task itself and prevent duplicate choices; a missing candidate remains visible by ID until explicitly removed. Clear all only changes the local draft; Save dependencies is the explicit durable action, including saving an empty set. The UI does not validate the DAG: the durable domain owns missing, self, duplicate and cycle rejection.

Dependency editing shares the existing one-pending-command gate, secure UUID seam, typed `set_task_dependencies_command` builder, live revision and authenticated WebSocket transport. There is no second command queue, optimistic projection or automatic retry. Events update the replica before the correlated result settles; rejection and uncertain disconnects preserve the draft under the same reconciliation rules as task editing.

A draft retains its opening dependency set. If an external authoritative update changes that set, saving is blocked until **Reload latest dependencies** explicitly replaces the draft, or the user discards it. Unrelated revision changes leave the draft intact and submission uses the latest revision. A draft survives switching or dismissing the inspector; **Return to draft** and **Discard draft** provide explicit navigation and disposal. Removing its target in an authoritative snapshot discards it with a notice. Only one editor is active at a time; other mutation controls are disabled while editing dependencies, and all draft mutation controls are disabled while a command is pending.

## View

Seven lanes cover Created, Refining, Ready, Running, Review, Done, and Suspended. Cards show title, priority, ID, dependency/attempt counts, description preview, running/latest attempt status, and the v1 Edit/Move controls. The header shows connection status, Board revision, stream sequence, task count, and the New task entry. Loading and empty are distinct: until an authoritative snapshot arrives — and again after any invalidation, which discards every record — the board shows `Waiting for Board state`; only an authoritative empty board shows `No Board tasks yet`, so stale cards never survive a resync.

The view uses semantic HTML and a small Board-owned stylesheet.

## Cross-host contract

This module is Rabbita's one browser client implementation. SvelteKit 3 and Proton-style desktop hosts implement the same wire schema and reducer invariants themselves; they neither frame this shell in an iframe nor import Rabbita or this MoonBit presentation. The canonical command names and argument schemas (`board.task.create`, `board.task.update`, `board.task.move`, `board.task.set_dependencies`), the stable rejection codes, the `posoco-ext-board/protocol-fixtures/v1` fixtures, and the client enum wire spellings (`ClientBoardPriority::to_wire`, `ClientBoardStage::to_wire`) are the shared contract for those adapters. This module imports only the Board client/protocol surface, not backend, coordinator, store, native host, or MoonBack packages.

## Validation

```bash
moon -C posoco-ext-board-web check --target js --output-json
moon -C posoco-ext-board-web test src --target js --output-json
```

Presentation, connection-policy and mutation tests are deterministic helper/update tests, not a new DOM harness. Native static/security and WebSocket tests verify the standalone integration separately. Inspector and dependency tests cover detached drafts, external changes, safe rejections, event/result ordering and Hello-only reconnects. Attempt/review controls, Cetas/SvelteKit integration, Agent execution and scheduling remain out of scope.
