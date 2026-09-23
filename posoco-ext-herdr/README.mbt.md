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
| `HerdrDelegate` | `Lifecycle` / `Observer` | captures the composed `Tasks` capability and tracks the parent session (background support) |
| `HerdrDelegate` | `Extension` | id `posoco_ext_herdr_delegate`; that tool and prompt section, requires `Capability::Tasks` |

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
UserRequestStarted     →  … --state blocked --message <bounded prompt>
UserRequestFinished    →  … --state working
TurnCompleted          →  … --state idle
TurnFailed             →  … --state idle
registration (once)    →  … --state idle
Agent shutdown         →  herdr pane release-agent <pane> --source cetas --agent cetas
```

State vocabulary is fixed by the installed herdr CLI:
`idle | working | blocked | unknown`. **There is no `done` state** in the
installed version (herdr.dev docs describe one, but the CLI rejects it), so
both turn terminals report `idle` — "agent available again".

`blocked` fires when a permission confirm, plan review, or ask_question
enters the composed `UiPort` (`UserRequestStarted` from posoco core's
request-event wrapper); the prompt travels as a bounded single-line
`--message` so herdr's rollup — and its "needs you" notification — fire the
moment the agent waits for the user. `UserRequestFinished` returns the state
to `working` until the turn terminates. Requests that resolve no UI emit a
brief `blocked → working` pair (`outcome=unsupported`); that is truthful
telemetry of an attempted ask, and UI-less compositions (NoopUiPort) emit
nothing at all.

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
herdr pane run         <new pane> "cetas-headless --permission readonly -- '<task>' ; echo '[cetas-headless] pane-id'le"
herdr pane wait-output --regex "\[cetas-headless\] (turn [0-9]+ done|turn failed:|pane-idle)" --source recent-unwrapped --timeout <ms> <new pane>
herdr pane read        <new pane> --source recent-unwrapped
                                     (re-run once, best-effort, after a timeout to capture child_session)
herdr pane close       <new pane>   (only after a successful read; skipped when close_pane=false)
```

The `pane run` command ends with a trailing `; echo '[cetas-headless] pane-id'le`
(the idle sentinel). The launcher types it split across a quote boundary so the
command-line echo never contains the full literal `[cetas-headless] pane-idle` —
only the executed echo's output does. When the child exits (any exit path,
including a startup crash) the echo prints and the pane is back at a
command-ready state.

The wait matches one Rust regex (substring semantics, unanchored, `--source
recent-unwrapped` so pty line-wrapping cannot break it) covering the three
terminal shapes: the completion marker `[cetas-headless] turn N done`, the
failure line `[cetas-headless] turn failed: …`, and the idle sentinel. The
child is one-shot headless (one task, one turn), so a healthy run ends at
`turn 1 done`; a startup failure ends at the failure line; anything else ends
at the sentinel. `wait-output` matches pre-existing output first (the typed
command echo included), which is exactly why the sentinel is quote-split.

### Tool arguments

| argument | type | default | meaning |
|---|---|---|---|
| `task` | string, required | — | the delegated task; must be a single line — a newline is rejected before any CLI call, since it would escape the one `pane run` argv element into separate shell commands |
| `permission` | `"readonly"` / `"write"` | `readonly` | readonly launches `cetas-headless --permission readonly` (cannot write); write launches `--yolo` (unattended full permission) |
| `model` | string | — | forwarded to the child as `--model`; an empty string is treated as omitted |
| `effort` | string | — | forwarded to the child as `--effort`; an empty string is treated as omitted |
| `session` | string | — | a `child_session` id from an earlier result or error footer (returned on success, failure, and best-effort timeout); re-launches headless with `--session` to continue that child. Related tasks must reuse the same child session instead of spawning a new one. Omit it for a new conversation — never pass an empty string (an empty string is treated as omitted) |
| `timeout_ms` | integer | `1800000` (30 min) | wait bound for the completion marker |
| `direction` | `"right"` / `"down"` | `right` | direction of the split |
| `close_pane` | boolean | `true` | auto-close the child pane after a successful read; the pane is never closed on failure or timeout (a timed-out child may still be running and its pane stays for inspection); pass `false` to always keep the pane |
| `background` | boolean | `false` | return a receipt immediately and run the delegation through the Agent-owned task capability (core `Tasks`); the result arrives later as a follow-up turn. Background always starts a fresh child and cannot take `session` (see below) |

### Result contract

- Success: the headless answer, then a footer — `peer_pane: <new pane id>`
  and, when the pane showed a `session: <id>` line, `child_session: <id>`.
  Pass the child session back via `session` to continue that child. On this
  success path the child pane is then closed (default `close_pane=true`);
  when `pane close` itself fails the result still succeeds, with a final
  `note: pane auto-close failed (pane still open)` footer line.
- The child's own failure (a `[cetas-headless] turn failed: <reason>` line
  on the pane) surfaces as a tool error carrying the reason, `peer_pane`,
  and — when the pane showed a session line — `child_session`. A startup
  failure (the headless launcher exiting with code 2 before any turn) prints
  the same shape first — `[cetas-headless] turn failed: startup: …` — so the
  wait catches it and the delegate reports it like any child failure. A child
  that exits without printing any protocol line at all is still terminated
  promptly by the idle sentinel; the delegate then reports
  `child exited before printing a completion marker` with a bounded excerpt
  of the pane screen (the real death cause — a usage error, a missing
  binary, an env failure). A marker timeout is likewise a tool error, noting
  that the pane is left open and
  the child may still be running; the delegate then reads the pane once,
  best-effort, to capture `child_session` (a failed read is silently
  omitted). `child_session` is returned on success, failure, and
  (best-effort) timeout; related work should resume the same session via
  the `session` argument. Every CLI step failure (split / run / wait /
  read) is a model-visible tool error; only spawn/transport breakage
  raises. The pane is never auto-closed on any of these paths.

  read) is a model-visible tool error; only spawn/transport breakage
  raises. The pane is never auto-closed on any of these paths.

### Background delegations

`background: true` returns a receipt immediately and runs the same
five-step channel flow through the Agent-owned task capability (core
`Tasks`):

```
background herdr_delegate accepted
delegation_id: agent_task_…
a fresh pane and child session will start; the result arrives as a follow-up turn
```

Host contract: compose `HerdrDelegate` (its manifest declares
`requires: [Capability::Tasks]` and contributes the delegate value as
Lifecycle + Observer) and run the agent under `Agent::run_scoped`.
`on_compose` captures the composed `Tasks`; `on_event_at` tracks the parent
session from scoped events, and the background `TaskSpec` is addressed to
that session. The receipt's `delegation_id` is the opaque core task id; core
delivers the delegation's terminal result to the same session as a follow-up
user message on its next ordinary `run_turn` (no automatic wakeup, and
results are not lost when a save fails — core retries). A failed or
timed-out delegation is still delivered as text (its `peer_pane` /
`child_session` footer matters for follow-up); only transport breakage is
classified by core as a failed task. There is no extension-side queue, flush
hook, or parent binding.

Constraints: `background` always starts a **fresh child** and is refused at
parse together with `session` — a timed-out child may still be running in
its pane and the delegate cannot distinguish it from a finished one, so
resume stays foreground-only. Core's task timeout is a last-resort
cancellation net set to `timeout_ms + 5000`: the channel flow's own
`pane wait-output` bound (which leaves the pane open and best-effort
captures `child_session`) always wins the race. Background delegations hold
a concurrency-cap slot from accept until the flow exits. Submitting outside
`run_scoped` (or before composition) is a model-visible tool error, not a
crash. The runner guards both exit paths with `pause()`, so a cancelled
coroutine stays cancelled — core records `cancelled`/`timed out`, never a
Completed result with garbage. Tests: `src/background_wbtest.mbt`
(scripted CLI on the injected channel runner — no process).

### Guardrails and limits

- **Depth 1** — hosts never wire delegation tools into cetas-headless, so a
  delegated child cannot split further panes.
- **Concurrency cap 4** — a fifth in-flight delegate is refused until an
  earlier one finishes; background delegations hold their slot from accept
  until the channel flow exits (or the task is cancelled).
- The pane read is **screen text** (`--source recent-unwrapped`): what
  returns is what the pane shows, and a long answer can be truncated by the
  pane buffer — this is not a captured pipe.
- Exit fidelity comes from the pane text — the wait regex's three terminal
  shapes (marker / failure line / idle sentinel) — not from the child's exit
  code; the child runs inside the pane's shell and its status is not captured.
- Known risk (pre-existing class): a task whose text itself contains marker
  or sentinel literals can fake or premature-match a terminal shape. The
  single-line check plus shell quoting prevents command injection; they do
  not prevent marker-string injection.
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
