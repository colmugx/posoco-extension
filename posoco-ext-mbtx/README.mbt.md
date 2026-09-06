# posoco-ext-mbtx

A sandboxed command-and-script tool extension for [Posoco](https://mooncakes.io/docs/colmugx/posoco).
It contributes two tools:

- `mbtx` — the model submits a single-file MoonBit (`.mbtx`) program, the
  extension compiles it (`moon run --build-only`) and runs the artifact under
  `moonrun --policy` (`src/posoco_ext_mbtx.mbt:22-29`, `src/pipeline.mbt:97-102`).
- `cmd` — the model runs ONE allowlisted program as literal argv straight
  through the Runner: no compile, no policy, no toolchain requirement
  (`src/pipeline.mbt:475-516`).

Routing rule: a single whitelisted command goes through `cmd`; multi-step
orchestration (pipes, sequencing, glue) goes through `mbtx` as a MoonBit
script. There is no shell anywhere — subprocesses spawn as literal argv
constrained by a code-reviewable program allowlist, and `mbtx` file writes
are confined to the call's temporary directory.

> **Targets:** native, wasm and js ship the full execution face on one shared
> pipeline (`src/pipeline.mbt`). native and wasm run through
> the `@process`/`@fs` edge (`src/posoco_ext_mbtx.native.mbt`) — on wasm the
> host embedder must provide the moonbitlang/async host imports (moonrun or
> equivalent) and its policy must allow `moon`/`moonrun` spawn. js forwards to
> the Bun runtime (`src/posoco_ext_mbtx.js.mbt`: `Bun.spawn` literal argv,
> `Bun.which` probing, node:fs sync IO). Any other backend is inert: it lists
> no tool and `execute` raises immediately (`src/fallback.mbt:10-28`).

## Ports contributed

| Port | Contribution |
|------|--------------|
| `ToolProvider` | The `mbtx` and `cmd` ToolDefs/schemas plus the two-stage execution pipeline (`src/pipeline.mbt:34-58`, `src/manifest.mbt:7-22`) |
| `SystemPromptContributor` | Injects the command charter: positive capability statement, allowlist table, excluded face, coreutils substitutions, copy-paste snippets, anti-paralysis line; byte-stable for the agent's lifetime (`src/prompt.mbt:66-83`) |
| `Extension` | Composes into `Agent(exts=[..])` as `posoco_ext_mbtx` (`src/manifest.mbt:2-22`, `src/extends.mbt:7-13`) |

## Usage

> No in-repo consumer exists yet (host wiring is intentionally deferred), so
> the compose fragment below is illustrative rather than copied from a host.

```bash
moon add colmugx/posoco-ext-mbtx
```

```moonbit nocheck
// moon.pkg: "colmugx/posoco-ext-mbtx" @mbtx

let agent = Agent(
  exts=[
    @mbtx.mbtx_extension(), // defaults: default allowlist + 120s run budget + sandbox-face exemption self-report
    // For the per-call-approved escalation face, construct explicitly:
    // @mbtx.MbtxTools(escalation=true, anchor=Some(anchor)),
    ..,
  ],
  config~,
)
```

Scripts are read-only toward the workspace: file changes go through the
host's write/edit tools, never from inside the script
(`src/pipeline.mbt:362-371`, `src/prompt.mbt:78`).

## `mbtx` call arguments

| Argument | Type | Meaning |
|----------|------|---------|
| `source` | string, required | Full single-file `.mbtx` program source; empty or non-string values are typed errors (`src/posoco_ext_mbtx.mbt:205-274`) |
| `target` | string | `wasm` (default) / `wasm-gc` / `js` / `llvm`; `native` is rejected at decode time — the moonrun policy can only bind wasm-family backends (`src/posoco_ext_mbtx.mbt:234-246`) |
| `escalated` | boolean | Present in the schema only when constructed with `escalation=true`; that one call runs without the sandbox policy (`src/posoco_ext_mbtx.mbt:256-274`, `src/pipeline.mbt:151-154`) |

## `cmd` call arguments

| Argument | Type | Meaning |
|----------|------|---------|
| `program` | string, required | Program to run; must match the allowlist exactly (exact name, no paths, no resolution); empty or non-string values are typed errors (`src/pipeline.mbt:383-436`) |
| `args` | string array, optional | Literal argv elements, defaults to `[]`; every item must be a string, or the call is a typed decode error (`src/pipeline.mbt:383-436`) |

There is no `escalated` and no `target` — `cmd` never drops governance and
never touches the compiler.

`cmd` execution semantics (`src/pipeline.mbt:439-516`):

1. **Allowlist gate (extension-side, before any spawn)**: the program must
   match one allowlist rule exactly and every `args_prefix` element must
   match the argv prefix in order; an empty prefix admits any arguments
   (`src/pipeline.mbt:439-458`).
2. **Teaching refusal on a miss**: a `ToolReportedError` containing the full
   effective allowlist table, the excluded face, and the pointer "for
   multi-step orchestration use the mbtx tool" — the call never reaches a
   process spawn (`src/pipeline.mbt:464-472`).
3. **Direct execution on a hit**: `runner.run(program, args, cwd)` with cwd
   pinned to `anchor.root` (inherited when no anchor) and the
   `run_timeout_ms` wall-clock budget. Timeout/cancellation classification
   (child killed, "timed out" business error), non-zero exit and
   `invalid_utf8` reported errors, and 64KB tail-truncation map exactly like
   the `mbtx` RUN stage (`src/pipeline.mbt:475-516`).

`cmd` is not a shell: `|`, `>`, `&&`, `$()` and `*` have no special meaning —
every element of `args` is one literal argument (`src/pipeline.mbt:581-586`).

## Constructor arguments

`MbtxTools::MbtxTools(...)` in full (`src/posoco_ext_mbtx.mbt:87-95`):

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `anchor` | `None` | Working-directory anchor for the RUN stage and `cmd` (same semantics as the bash extension); `None` inherits the host process cwd (`:38`, `src/pipeline.mbt:156-159`, `:485-488`) |
| `allowlist_extra` | `[]` | Allowlist entries appended (`SpawnRule{program, args_prefix}`; empty `args_prefix` = any arguments); governs the moonrun policy AND the `cmd` gate (`:63-67`) |
| `allowlist_without` | `[]` | Removed from the default table by program name, e.g. `["git"]`; governs both tools (`src/posoco_ext_mbtx.mbt:147-161`) |
| `run_timeout_ms` | `120_000` | Wall-clock budget for the `mbtx` RUN stage and every `cmd` call; on expiry the child is killed and a `ToolReportedError` is reported (`:43`, `src/pipeline.mbt:160-166`, `:489-495`) |
| `escalation` | `false` | Accept `escalated:true` mbtx calls (that call drops the policy); the approval decision belongs to the approval layer (`:46-48`) — `cmd` has no escalated form |
| `toolchain_bin` | `None` | Explicit toolchain bin directory, first in the resolution order (`:49`, `src/toolchain.mbt:42-68`); `cmd` does not need a toolchain |
| `bus` | `None` | When set, the constructor publishes the `tool_exemptions` self-report on the bus (`:51-52`, `:174-184`) |

## Default allowlist

| Program | Argument constraint |
|---------|---------------------|
| `moon` / `git` / `gh` / `rg` / `diff` | any arguments (`src/posoco_ext_mbtx.mbt:72-83`) |

Everything else is denied — including any shell or interpreter (sh, bash,
zsh, fish, python, node, deno), `xargs`, and curl/wget piping
(`src/posoco_ext_mbtx.mbt:72-75`). The same effective table (default +
`allowlist_extra` − `allowlist_without`) governs `cmd`, enforced
extension-side before spawn. The allowlist appears in both tool descriptions
and the system prompt — missing either side is how the model drifts back to
shell habits (`src/posoco_ext_mbtx.mbt:289-301`, `src/prompt.mbt:77`,
`src/pipeline.mbt:581-586`). It is not a security perimeter; spawned children
get host ambient permissions — it buys the long tail of accidental damage.

## Execution pipeline (shared by all three targets)

One business pipeline (`src/pipeline.mbt`), per `mbtx` call:
resolve and cache the toolchain → create a one-shot tmpdir → write
`snippet.mbtx` and `policy.json` → two stages → cleanup (`:60-79`,
`:91-187`). Process/file primitives live behind each target's execution edge
(the `Runner` trait plus the `mbtx_call_tmpdir` / `mbtx_write_file` /
`mbtx_cleanup_tmpdir` / `mbtx_realpath` file seams,
(`src/posoco_ext_mbtx.mbt:11-19`)):

1. **BUILD** (10s budget): `moon run snippet.mbtx --build-only --target <t>
   --target-dir <tmp>/build`; `moon` never executes the snippet. A non-zero
   exit yields `ToolReportedError` with tmp paths in the diagnostics rewritten
   back to `snippet.mbtx:LINE:COL`; the `artifacts_path` JSON line is then
   parsed from stdout (`src/pipeline.mbt:24-27`, `:103-150`,
   `:238-273`).
2. **RUN** (`run_timeout_ms` budget): `moonrun <artifact> --policy
   policy.json`, cwd pinned to `anchor.root`; `escalated` calls drop
   `--policy`; timeouts kill the child
   (`src/pipeline.mbt:148-166`; live regression: infinite-loop
   snippet + 3s budget leaves no moonrun behind,
   `src/execute_live_wbtest.mbt:98-119`; js equivalent
   `src/js_runner_wbtest.mbt:163-186`).

`cmd` calls skip this pipeline entirely: no tmpdir, no policy, no toolchain —
the decoded argv goes straight to the same `Runner` seam with the
`run_timeout_ms` budget (`src/pipeline.mbt:475-516`).

**Timeout and process kill**: on native/wasm the stage runs inside
`@async.with_timeout`, whose cancellation tears the collection task down and
SIGTERMs the child (`src/posoco_ext_mbtx.native.mbt:8-14`). On js the async
timing layer cannot kill a Bun child it does not own, so the budget is
enforced extern-side: `Promise.race([proc.exited, setTimeout(kill)])`, then a
1s pipe drain, and the runner raises the package-local
`MbtxBudgetExpired` marker, which `timed_stage` classifies into the same
"timed out" business error as the library's TimeoutError/cancellation
(`src/posoco_ext_mbtx.js.mbt:10-15`, `:33-71`, `:191-227`,
`src/pipeline.mbt:196-229`).

Output is truncated at 64KB (tail kept, one notice line prepended; BUILD
diagnostics included); undecodable (non-UTF-8) output is reported as
`invalid_utf8` rather than masquerading as success
(`src/pipeline.mbt:30-31`, `:171-187`, `:279-293`). The tmpdir
is cleaned best-effort on every path. Business-level failures (compile
failure, timeout, non-zero exit) return `ToolReportedError`;
`RuntimeError` is reserved for infrastructure failures (missing toolchain,
unusable tmpdir, `:60-79`).

### js execution edge (Bun forwarding)

Same conventions as the other cetas js extensions (`src/posoco_ext_mbtx.js.mbt`):
processes always via `Bun.spawn` literal argv (never node:child_process); file
IO via node:fs sync APIs; PATH probing via `Bun.which`. Everything throwing
crosses the FFI as a JSON string envelope decoded with `@json` on the
MoonBit side (docs/questions.md 2026-08-19 boundary). `Response.text()` never yields
invalid UTF-8, so the decoded channel is always true on js (`:228-230`).

## Permission model

- **Sandboxed `mbtx` face is exempt**: the constructor self-reports
  `tool_exemptions` (tools=`["mbtx"]`) on the bus — exemptions are a trust
  channel, not a security boundary; the sandboxed call's governance is
  structural in the moonrun policy (`src/posoco_ext_mbtx.mbt:163-184`).
- **`cmd` is never exempt**: the self-report stays exactly
  `{"tools":["mbtx"]}` — `cmd` has no sandbox face of its own (the allowlist
  is a vocabulary, not a policy sandbox), so every `cmd` call traverses the
  approval gate. The permission package's shell classification already lists
  `cmd` by name (`posoco-ext-permission/src/permission.mbt:140`).
- **Escalated is gated per call**: `escalated:true` does not ride the
  exemption — the companion rule in `posoco-ext-permission` intercepts BEFORE
  the exemption lookup, requires per-call consent (scope `mbtx:escalated`),
  and demotes `AllowSession`/`AllowAlways` to per-call consent that is never
  written to `session_approved`
  (`posoco-ext-permission/src/permission.mbt:507-573`, `:590-596`).

## Toolchain requirements

Both `moon` and `moonrun` must be executable for `mbtx`; resolution order is
`toolchain_bin` → PATH (scanned in order) → `~/.moon/bin`, the first usable
directory is cached, and total failure raises
"mbtx: no MoonBit toolchain found ..." (`src/toolchain.mbt:42-101`).
Probing is per target: `@fs.can_execute` on native/wasm
(`src/posoco_ext_mbtx.native.mbt:110-123`), `Bun.which(name, {PATH: dir})` on
js — both check executability, not mere existence
(`src/posoco_ext_mbtx.js.mbt:330-338`). Verified against
**moon 0.1.20260827** (the policy schema is checked against that version,
`src/policy.mbt:1-9`). `cmd` has no toolchain requirement — it only needs the
allowlisted program itself to be resolvable by the host.

## Prompt surface

The system prompt carries the positive capability statement ("a single
whitelisted command goes straight through `cmd` ... you can run moon, git,
gh, rg, diff"), the allowlist table, the excluded face, coreutils
substitutions, four copy-paste snippet templates (verified against the
vendored moonbitlang/async sources and compiled with `moon run --target
wasm`: run one command, list a directory with kind/size, glob, bounded
output), and one anti-paralysis line ("submit anyway — a BUILD failure is
cheap and tells you exactly what to fix") (`src/prompt.mbt:9-83`,
`src/pipeline.mbt:362-371`). All of it is derived only from constructor
state, so the `SystemPromptContributor` output is byte-stable for the
agent's lifetime.

## Offline behavior

Pure-core programs (no imports) build offline; programs with imports (e.g.
`moonbitlang/async/shell`) require a warm registry — one `moon update` on
first use, nothing is fetched automatically (`src/prompt.mbt:82`). Note that
`async fn main` requires importing `moonbitlang/async` even when only
`@shell`/`@fs` are used (the snippets show the full import block).

## Known limitations

- **No background jobs**: long tasks such as `moon test` are bounded by
  `run_timeout_ms` (default 120s) and killed on expiry.
- **`cmd` asks per call in Interactive mode**: the permission gate's
  read-only pre-approval matches raw shell command strings, so it cannot
  classify structured argv — every `cmd` call is approved individually.
  Accepted safe default; Yolo/allowlist modes are unaffected.
- **`cmd` allowlist is not a sandbox**: it constrains the vocabulary, not
  capabilities — the spawned program runs with host ambient permissions
  (`src/posoco_ext_mbtx.mbt:72-75`).
- **wasm requires a host embedder** (moonrun or equivalent) providing the
  moonbitlang/async host imports, with its policy allowing spawn.
- **js face**: the default test runner for `moon test --target js` is node
  (no `Bun` global), so js tests must run the generated driver under bun (a
  node→bun shim on PATH ran the suite 10/10 locally); `Response.text()` never
  reports `invalid_utf8` (decoded channel always true); the js budget is
  timed extern-side in addition to `@async.with_timeout`, and both classify
  as "timed out".
- An externally aborted turn is reported as "timed out" too — accepted
  trade-off: the child is killed and the call errors either way
  (`src/pipeline.mbt:189-195`).
- The allowlist and the policy are not security boundaries: the policy
  constrains the script itself, not the children it spawns — children get
  host ambient permissions (`src/posoco_ext_mbtx.mbt:72-75`,
  `src/policy.mbt:1-9`).
