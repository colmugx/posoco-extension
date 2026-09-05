# posoco-ext-mbtx

A sandboxed MoonBit script tool extension for [Posoco](https://mooncakes.io/docs/colmugx/posoco).
It contributes one tool, `mbtx`: the model submits a single-file MoonBit
(`.mbtx`) program, the extension compiles it (`moon run --build-only`) and
runs the artifact under `moonrun --policy`. There is no shell anywhere —
subprocesses spawn as literal argv constrained by a code-reviewable program
allowlist, and file writes are confined to the call's temporary directory
(`src/posoco_ext_mbtx.mbt:26-29`, `src/pipeline.mbt:97-99`).

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
| `ToolProvider` | The single `mbtx` ToolDef/schema and the two-stage execution pipeline (`src/pipeline.mbt:34-50`, `src/manifest.mbt:7-22`) |
| `SystemPromptContributor` | Injects the shell-free charter: allowlist table, excluded face, coreutils substitutions; byte-stable for the agent's lifetime (`src/prompt.mbt:7-15`) |
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
(`src/pipeline.mbt:355-361`, `src/prompt.mbt:12`).

## `mbtx` call arguments

| Argument | Type | Meaning |
|----------|------|---------|
| `source` | string, required | Full single-file `.mbtx` program source; empty or non-string values are typed errors (`src/posoco_ext_mbtx.mbt:199-272`) |
| `target` | string | `wasm` (default) / `wasm-gc` / `js` / `llvm`; `native` is rejected at decode time — the moonrun policy can only bind wasm-family backends (`src/posoco_ext_mbtx.mbt:228-240`) |
| `escalated` | boolean | Present in the schema only when constructed with `escalation=true`; that one call runs without the sandbox policy (`src/posoco_ext_mbtx.mbt:250-270`, `src/pipeline.mbt:144-149`) |

## Constructor arguments

`MbtxTools::MbtxTools(...)` in full (`src/posoco_ext_mbtx.mbt:86-94`):

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `anchor` | `None` | Working-directory anchor for the RUN stage (same semantics as the bash extension); `None` inherits the host process cwd (`:35-37`) |
| `allowlist_extra` | `[]` | Allowlist entries appended (`SpawnRule{program, args_prefix}`; empty `args_prefix` = any arguments) (`:62-66`) |
| `allowlist_without` | `[]` | Removed from the default table by program name, e.g. `["git"]` (`src/posoco_ext_mbtx.mbt:139-156`) |
| `run_timeout_ms` | `120_000` | RUN-stage wall-clock budget; on expiry the child is killed and a `ToolReportedError` is reported (`:41-42`, `src/pipeline.mbt:153-160`) |
| `escalation` | `false` | Accept `escalated:true` calls (that call drops the policy); the approval decision belongs to the approval layer (`:43-45`) |
| `toolchain_bin` | `None` | Explicit toolchain bin directory, first in the resolution order (`:46-48`, `src/toolchain.mbt:42-68`) |
| `bus` | `None` | When set, the constructor publishes the `tool_exemptions` self-report on the bus (`:49-50`, `:168-178`) |

## Default allowlist

| Program | Argument constraint |
|---------|---------------------|
| `moon` / `git` / `gh` / `rg` / `diff` | any arguments (`src/posoco_ext_mbtx.mbt:72-83`) |

Everything else is denied — including any shell or interpreter (sh, bash,
zsh, fish, python, node, deno), `xargs`, and curl/wget piping
(`src/posoco_ext_mbtx.mbt:72-75`). The allowlist appears in both the tool
description and the system prompt — missing either side is how the model
drifts back to shell habits (`src/posoco_ext_mbtx.mbt:280-295`,
`src/prompt.mbt:2-6`). It is not a security perimeter; spawned children get
host ambient permissions — it buys the long tail of accidental damage.

## Execution pipeline (shared by all three targets)

One business pipeline (`src/pipeline.mbt`), per call:
resolve and cache the toolchain → create a one-shot tmpdir → write
`snippet.mbtx` and `policy.json` → two stages → cleanup (`:53-79`,
`:81-179`). Process/file primitives live behind each target's execution edge
(the `Runner` trait plus the `mbtx_call_tmpdir` / `mbtx_write_file` /
`mbtx_cleanup_tmpdir` / `mbtx_realpath` file seams,
(`src/posoco_ext_mbtx.mbt:11-19`)):

1. **BUILD** (10s budget): `moon run snippet.mbtx --build-only --target <t>
   --target-dir <tmp>/build`; `moon` never executes the snippet. A non-zero
   exit yields `ToolReportedError` with tmp paths in the diagnostics rewritten
   back to `snippet.mbtx:LINE:COL`; the `artifacts_path` JSON line is then
   parsed from stdout (`src/pipeline.mbt:25-27`, `:99-143`,
   `:231-267`).
2. **RUN** (`run_timeout_ms` budget): `moonrun <artifact> --policy
   policy.json`, cwd pinned to `anchor.root`; `escalated` calls drop
   `--policy`; timeouts kill the child
   (`src/pipeline.mbt:144-160`; live regression: infinite-loop
   snippet + 3s budget leaves no moonrun behind,
   `src/execute_live_wbtest.mbt:98-119`; js equivalent
   `src/js_runner_wbtest.mbt:163-186`).

**Timeout and process kill**: on native/wasm the stage runs inside
`@async.with_timeout`, whose cancellation tears the collection task down and
SIGTERMs the child (`src/posoco_ext_mbtx.native.mbt:8-14`). On js the async
timing layer cannot kill a Bun child it does not own, so the budget is
enforced extern-side: `Promise.race([proc.exited, setTimeout(kill)])`, then a
1s pipe drain, and the runner raises the package-local
`MbtxBudgetExpired` marker, which `timed_stage` classifies into the same
"timed out" business error as the library's TimeoutError/cancellation
(`src/posoco_ext_mbtx.js.mbt:10-15`, `:33-71`, `:191-227`,
`src/pipeline.mbt:208-219`).

Output is truncated at 64KB (tail kept, one notice line prepended; BUILD
diagnostics included); undecodable (non-UTF-8) output is reported as
`invalid_utf8` rather than masquerading as success
(`src/pipeline.mbt:29-30`, `:167-179`, `:272-280`). The tmpdir
is cleaned best-effort on every path. Business-level failures (compile
failure, timeout, non-zero exit) return `ToolReportedError`;
`RuntimeError` is reserved for infrastructure failures (missing toolchain,
unusable tmpdir, `:53-79`).

### js execution edge (Bun forwarding)

Same conventions as the other cetas js extensions (`src/posoco_ext_mbtx.js.mbt`):
processes always via `Bun.spawn` literal argv (never node:child_process); file
IO via node:fs sync APIs; PATH probing via `Bun.which`. Everything throwing
crosses the FFI as a JSON string envelope decoded with `@json` on the MoonBit
side (docs/questions.md 2026-08-19 boundary). `Response.text()` never yields
invalid UTF-8, so the decoded channel is always true on js (`:228-230`).

## Permission model

- **Sandboxed face is exempt**: the constructor self-reports
  `tool_exemptions` (tools=`["mbtx"]`) on the bus — exemptions are a trust
  channel, not a security boundary; the sandboxed call's governance is
  structural in the moonrun policy (`src/posoco_ext_mbtx.mbt:158-178`).
- **Escalated is gated per call**: `escalated:true` does not ride the
  exemption — the companion rule in `posoco-ext-permission` intercepts BEFORE
  the exemption lookup, requires per-call consent (scope `mbtx:escalated`),
  and demotes `AllowSession`/`AllowAlways` to per-call consent that is never
  written to `session_approved`
  (`posoco-ext-permission/src/permission.mbt:507-573`, `:590-596`).

## Toolchain requirements

Both `moon` and `moonrun` must be executable; resolution order is
`toolchain_bin` → PATH (scanned in order) → `~/.moon/bin`, the first usable
directory is cached, and total failure raises
"mbtx: no MoonBit toolchain found ..." (`src/toolchain.mbt:42-101`).
Probing is per target: `@fs.can_execute` on native/wasm
(`src/posoco_ext_mbtx.native.mbt:110-123`), `Bun.which(name, {PATH: dir})` on
js — both check executability, not mere existence
(`src/posoco_ext_mbtx.js.mbt:330-338`). Verified against
**moon 0.1.20260827** (the policy schema is checked against that version,
`src/policy.mbt:1-9`).

## Offline behavior

Pure-core programs (no imports) build offline; programs with imports (e.g.
`moonbitlang/async/shell`) require a warm registry — one `moon update` on
first use, nothing is fetched automatically (`src/prompt.mbt:14`).

## Known limitations

- **No background jobs**: long tasks such as `moon test` are bounded by
  `run_timeout_ms` (default 120s) and killed on expiry.
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
  (`src/pipeline.mbt:183-188`).
- The allowlist and the policy are not security boundaries: the policy
  constrains the script itself, not the children it spawns — children get
  host ambient permissions (`src/posoco_ext_mbtx.mbt:72-75`,
  `src/policy.mbt:1-9`).
