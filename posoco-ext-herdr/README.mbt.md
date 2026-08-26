# posoco-ext-herdr

> **Targets: native + js (bun); compiles inert elsewhere**

Herdr presence for [Posoco](https://mooncakes.io/docs/colmugx/posoco) agents.
When the host process runs inside a [herdr](https://herdr.dev) pane, this
extension makes the agent appear in herdr's agent rollup with live lifecycle
state — **zero changes to posoco core, one read-only `Observer` port**.

## Ports contributed

| Port | Contribution |
|------|--------------|
| `Observer` | maps turn lifecycle onto herdr agent states by shelling `herdr pane report-agent` |
| `Extension` | contributes that observer and nothing else — no tools, no hooks, no prompt sections |

The constructor is the gate: without `HERDR_ENV` in the process environment it
returns `None` and nothing registers — outside herdr the cost is one
environment probe at startup. Which herdr concerns exist beyond presence
(peer delegation, socket subscriptions) is NOT this extension's concern; see
Future directions.

## Usage

```bash
moon add colmugx/posoco-ext-herdr
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-herdr" @herdr

match @herdr.HerdrReporter::detect() {
  Some(reporter) => exts.push(reporter as &@posoco.Extension)
  None => ()
}
```

Copied from cetas-core's `build_default_features`, which gates detection
behind `detect_herdr? : Bool = true`; hosts composing it inherit herdr
presence automatically.

## Event mapping

```text
TurnStarted            →  herdr pane report-agent <pane> --source cetas --agent cetas --state working
TurnCompleted          →  … --state idle
TurnFailed             →  … --state idle
registration (once)    →  … --state idle
```

State vocabulary is fixed by the installed herdr CLI:
`idle | working | blocked | unknown`. **There is no `done` state** in the
installed version (herdr.dev docs describe one, but the CLI rejects it), so
both turn terminals report `idle` — "agent available again". `blocked` is
reserved for a future UiPort hook.

## Behavior per target

| target | detection | report | notes |
|---|---|---|---|
| native | one `sh -c printf` via `@process` at startup | libc `system()` with the command backgrounded and silenced | the sync `Observer` callback blocks only for the fork+exec of `/bin/sh`, at turn boundaries; failures are swallowed by design — presence reporting must never fail a turn |
| js (bun) | `Bun.env` (synchronous) | `Bun.spawn` with stdio ignored, fire-and-forget | genuinely non-blocking |
| wasm / wasm-gc | — | — | compiles as fully inert; constructor returns `None` |

herdr injects `HERDR_ENV`, `HERDR_PANE_ID` (and optionally
`HERDR_SOCKET_PATH`) into managed panes; the reporter reads the first two and
honors `HERDR_BIN_PATH` (default `herdr`). The CLI inherits the environment,
so the socket path needs no explicit plumbing.
