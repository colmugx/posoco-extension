# posoco-ext-board-web

A read-only Rabbita standalone browser shell for the Board wire contract.

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

This browser-only command produces `dist/index.html`, `dist/index.js`, and `dist/board.css`. Build output is ignored, not committed. No server entry or native asset embedding is included.

For a scaffold preview:

```bash
warren -C posoco-ext-board-web dev --browser-entry cmd/browser --server-entry ""
```

Without a Board instance token the shell stays Offline. A live connection requires serving these assets from a Board-capable host on the same origin with `/?token=<instance-token>`. This PR **does not** wire the assets into the native MoonBack host: its `/` still serves the existing diagnostics page. Preview is not a cross-origin proxy or an alternate Board backend.

## Contract

The app reads protocol, host, and query parameters from the current location. A minimal JS FFI helper supplies the location access missing from Rabbita and uses browser URL parsing; WebSocket operations themselves use Rabbita's `connect`, `send`, and `close`, with connection ID `board`.

`http:` maps to `ws:`, `https:` to `wss:`, always at the same host and `/ws`. Tokens are never written to local/session storage, rendered, or logged. Transport failure details and protocol messages are not displayed.

A fresh document starts with an empty replica. Opened sockets send the replica's Hello; only authoritative snapshots and full-entity Board events alter the projection. Unknown telemetry advances only the stream cursor. Gaps, inconsistent entities, unknown Board events and resync requests close the socket and reconnect for a snapshot. Protocol errors stop automatic retries.

Retries use Rabbita delayed commands: 250ms, 500ms, 1s, 2s, 4s, 8s, then a 10s cap. A valid snapshot resets the delay. One pending retry and connection-generation checks prevent duplicate schedules and stale socket callbacks from changing the current connection. Updates clone the replica before applying frames so incremental rendering never compares a mutated previous model.

## View

Seven lanes cover Created, Refining, Ready, Running, Review, Done, and Suspended. Cards show title, priority, ID, dependency/attempt counts, description preview and running/latest attempt status. The header shows connection status, Board revision, stream sequence, and task count. Empty boards show `No Board tasks yet`.

The view uses semantic HTML and a small Board-owned stylesheet. It deliberately contains no mutation controls, drag-and-drop, inspector, telemetry timeline or event dump.

## Embedded hosts

Future SvelteKit 3/Svelte 5 or desktop hosts should implement the same wire schema and reducer invariants using `posoco-ext-board/protocol-fixtures/v1`; they do not import Rabbita or embed this MoonBit presentation. This module imports only the Board client/protocol surface, not backend, coordinator, store, native host, or MoonBack packages.

## Validation

```bash
moon -C posoco-ext-board-web check --target js --output-json
moon -C posoco-ext-board-web test src --target js --output-json
```

Presentation and connection-policy tests are deterministic helper/update tests, not a new DOM harness. Native asset integration, UI mutations, Cetas/SvelteKit integration, Agent execution and scheduling remain out of scope.
