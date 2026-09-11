# posoco-ext-herdr

> **Targets: native + js (bun); compiles inert elsewhere**

Herdr for [Posoco](https://mooncakes.io/docs/colmugx/posoco) agents. When the
host process runs inside a [herdr](https://herdr.dev) pane, this extension
makes the agent visible to herdr twice over: it reports lifecycle presence to
herdr's agent rollup, and it offers one delegation tool that spawns a fresh
cetas-headless agent in a neighboring pane. Zero changes to posoco core.

## Ports contributed

Two extensions ship from this package; each contributes exactly one port.

| Struct | Port | Contribution |
|--------|------|--------------|
| `HerdrReporter` | `Observer` | maps turn lifecycle onto herdr agent states by shelling `herdr pane report-agent` |
| `HerdrReporter` | `Lifecycle` | releases the pane's herdr authority on Agent shutdown by shelling `herdr pane release-agent` |
| `HerdrReporter` | `Extension` | contributes that observer plus that lifecycle and nothing else — no tools, no hooks, no prompt sections |
| `HerdrDelegate` | `ToolProvider` | contributes exactly one tool, `herdr_delegate` |
| `HerdrDelegate` | `Extension` | id `posoco_ext_herdr_delegate`; that tool and nothing else |

Both constructors are environment-gated: without `HERDR_ENV` and
`HERDR_PANE_ID` (injected by herdr into managed panes) detection returns
`None` and nothing registers — outside herdr the cost is one environment
probe at startup. Presence and delegation are detected independently, so a
host may hold either alone.

## Usage

```bash
moon add colmugx/posoco-ext-herdr
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-herdr" @herdr

// copied from cetas-js/lib/cetas_js.mbt — both detections are env-gated:
match @herdr.HerdrReporter::detect() {
  Some(reporter) => exts.push(reporter as &@posoco.Extension)
  None => ()
}
match @herdr.HerdrDelegate::detect(cwd=runtime.config.cwd) {
  Some(delegate) => exts.push(delegate as &@posoco.Extension)
  None => ()
}
```

with `exts` feeding `Agent(exts=[..], config~)`. cetas-bun is the only
shipped outlet holding the delegate. cetas-headless wires the reporter only
(`lib/host.mbt`): **headless never composes `HerdrDelegate`** — it is a
depth-1 leaf by hard rule (2026-09-10), so a delegated child can never
delegate further.

## Presence (HerdrReporter)

```text
TurnStarted            →  herdr pane report-agent <pane> --source cetas --agent cetas --state working
TurnCompleted          →  … --state idle
TurnFailed             →  … --state idle
registration (once)    →  … --state idle
Agent shutdown         →  herdr pane release-agent <pane> --source cetas --agent cetas
```

State vocabulary is fixed by the installed herdr CLI:
`idle | working | blocked | unknown`. **There is no `done` state** in the
installed version (herdr.dev docs describe one, but the CLI rejects it), so
both turn terminals report `idle` — "agent available again". `blocked` is
reserved for a future UiPort hook.

The shutdown release is not optional: while a `cetas` source holds the
pane's lifecycle authority, herdr stops probing the pane's foreground
process itself, so without `release-agent` the agent entry survives the
process exiting and lingers in herdr's agent panel. Hosts that can exit
without an Agent (composition failure after registration) must call
`HerdrReporter::from_env()` + `release()` themselves — cetas-js does this
in its fatal-error path.

- **Not a tool provider** — the manifest contributes the observer and the
  lifecycle only. Presence reporting is read-only telemetry that must never
  fail a turn; failures are swallowed by design (verify manually by running
  the CLI command above when debugging).

## Delegation (HerdrDelegate)

One `herdr_delegate` call runs five CLI steps and returns the child's answer
as the tool result:

```text
herdr pane split       --pane <this pane> --direction <right|down> --cwd <host cwd> --no-focus
herdr pane run         <new pane> "cetas-headless --permission readonly -- '<task>'"
herdr pane wait-output --match "[cetas-headless] turn 1 done" --timeout <ms> <new pane>
herdr pane read        <new pane> --source recent-unwrapped
                                     (re-run once, best-effort, after a timeout to capture child_session)
herdr pane close       <new pane>   (only after a successful read; skipped when close_pane=false)
```

The child is one-shot headless (one task, one turn), so the wait matches the
fixed literal `[cetas-headless] turn 1 done`.

### Tool arguments

| argument | type | default | meaning |
|---|---|---|---|
| `task` | string, required | — | the delegated task; must be a single line — a newline is rejected before any CLI call, since it would escape the one `pane run` argv element into separate shell commands |
| `permission` | `"readonly"` / `"write"` | `readonly` | readonly launches `cetas-headless --permission readonly` (cannot write); write launches `--yolo` (unattended full permission) |
| `model` | string | — | forwarded to the child as `--model` |
| `effort` | string | — | forwarded to the child as `--effort` |
| `session` | string | — | a `child_session` id from an earlier result or error footer (returned on success, failure, and best-effort timeout); re-launches headless with `--session` to continue that child. Related tasks must reuse the same child session instead of spawning a new one |
| `timeout_ms` | integer | `1800000` (30 min) | wait bound for the completion marker |
| `direction` | `"right"` / `"down"` | `right` | direction of the split |
| `close_pane` | boolean | `true` | auto-close the child pane after a successful read; the pane is never closed on failure or timeout (a timed-out child may still be running and its pane stays for inspection); pass `false` to always keep the pane |

### Result contract

- Success: the headless answer, then a footer — `peer_pane: <new pane id>`
  and, when the pane showed a `session: <id>` line, `child_session: <id>`.
  Pass the child session back via `session` to continue that child. On this
  success path the child pane is then closed (default `close_pane=true`);
  when `pane close` itself fails the result still succeeds, with a final
  `note: pane auto-close failed (pane still open)` footer line.
- The child's own failure (a `[cetas-headless] turn failed: <reason>` line
  on the pane) surfaces as a tool error carrying the reason, `peer_pane`,
  and — when the pane showed a session line — `child_session`. A marker
  timeout is likewise a tool error, noting that the pane is left open and
  the child may still be running; the delegate then reads the pane once,
  best-effort, to capture `child_session` (a failed read is silently
  omitted). `child_session` is returned on success, failure, and
  (best-effort) timeout; related work should resume the same session via
  the `session` argument. Every CLI step failure (split / run / wait /
  read) is a model-visible tool error; only spawn/transport breakage
  raises. The pane is never auto-closed on any of these paths.

### Guardrails and limits

- **Depth 1** — hosts never wire delegation tools into cetas-headless, so a
  delegated child cannot split further panes.
- **Concurrency cap 4** — a fifth in-flight delegate is refused until an
  earlier one finishes.
- The pane read is **screen text** (`--source recent-unwrapped`): what
  returns is what the pane shows, and a long answer can be truncated by the
  pane buffer — this is not a captured pipe.
- Exit fidelity comes from the failure-line grep, not the child's exit code —
  the child runs inside the pane's shell and its status is not captured.
- Envelope v1: the task is sent as a plain (shell-quoted) line, without the
  `[cetas-peer from=… session=…]` attribution envelope.

## Environment gates

| variable | read by | meaning |
|---|---|---|
| `HERDR_ENV` + `HERDR_PANE_ID` | reporter and delegate | must be present and non-empty; absent → the extension is absent |
| `HERDR_BIN_PATH` | reporter and delegate | herdr CLI binary; defaults to `herdr` when absent or blank |
| `CETAS_HEADLESS_BIN` | delegate only | headless binary; defaults to `cetas-headless` when absent or blank |

The CLI inherits the environment, so herdr's socket path needs no explicit
plumbing.

## Behavior per target

| target | detection | CLI transport | notes |
|---|---|---|---|
| native | `@env` reads (synchronous, no subprocess) | `@process.collect_output` — stdout and stderr captured separately | herdr writes result JSON on stdout and error JSON on stderr, so merged capture would make a success read as an error |
| js (bun) | `Bun.env` (synchronous) | `Bun.spawn` with both streams piped; exit and drains awaited as one JSON envelope | the extern touches Bun only when invoked |
| wasm / wasm-gc | — | — | compiles as fully inert; both constructors return `None` |
