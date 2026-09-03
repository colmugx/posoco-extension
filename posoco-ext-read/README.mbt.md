# posoco-ext-read

[read tool for Posoco agents](https://mooncakes.io/docs/colmugx/posoco) — reads
a file as `L<line>: ` numbered lines with paged output, so a model can cite
lines and re-read exactly where a result was cut.

> **Targets: native + js** — native reads through `@fs` with line streaming
> (lines before `offset` are never materialized); js reads through node:fs
> sync APIs. On wasm/wasm-gc the tool is not listed and `execute` raises
> `InvocationFailed`.

## Ports contributed

| Port | Contribution |
|---|---|
| `ToolProvider` | the `read` tool |

## Usage

```bash
moon add colmugx/posoco-ext-read
```

```moonbit nocheck
// moon.pkg: "colmugx/posoco-ext-read" @read

// Share one guard/anchor with the write/edit tools so freshness and relative
// paths agree across the file tools (composition from cetas-core's
// build_default_features):
let freshness = @devkit.FreshnessGuard::FreshnessGuard()
let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor(ctx.cwd)
let exts : Array[&@posoco.Extension] = [
  @read.ReadTools(freshness~, anchor=Some(anchor)),
  // ... other extensions ...
]
let agent = Agent(exts=exts, config~)
```

`ReadTools::ReadTools(freshness?, anchor?, fs?)` takes all arguments optional:
without a `FreshnessGuard` the tool still reads, it just does not participate
in read-before-modify tracking; without an `anchor` relative paths resolve
against the process working directory. `read_extension()` is a zero-config
factory for hosts that want neither.

Editor delegation: pass `fs=Some(workspace_fs)` to serve file content through
an injected `WorkspaceFs` instead of the process filesystem — the seam a host
fronting an editor uses so reads can see unsaved-buffer state (e.g. an ACP
delegate riding `fs/read_text_file` with local fallback):

```moonbit nocheck
let exts : Array[&@posoco.Extension] = [
  @read.ReadTools(freshness~, anchor=Some(anchor), fs=Some(ctx.fs)),
  // ... other extensions ...
]
```

## Tool arguments

| Argument | Type | Meaning |
|---|---|---|
| `path` | string, required | file to read |
| `offset` | integer, optional | 1-indexed line to start from; negative counts back from the end of the file |
| `limit` | integer, optional | max lines returned (default 1000) |

## Output contract

- Lines are prefixed `L<line>: ` (1-indexed, no padding); long lines are cut
  at 2000 characters with a `… (line truncated)` marker.
- A page is bounded by `limit` (default 1000 lines) and a 100 KB output cap.
  When a cap cuts the page, the result ends with
  `… N more lines; call read with offset=M` — the model continues by calling
  back with that offset.
- `offset` past the end of the file is a `ToolReportedError` naming the total
  line count; an empty file reads as `(file exists but is empty)`.
- A file that is not valid UTF-8 is reported as a binary file (the message
  contains `is not valid UTF-8 (binary file)`) instead of decoding garbage.
- An explicit `offset`/`limit` range whose rendered output would exceed the
  byte cap is a loud `RuntimeError` telling the model to narrow the range —
  silent cutting is reserved for the implicit first page.
- CRLF line endings are normalized (`\r` stripped).

## Behavior notes

- **Freshness** — every successful read records a `(mtime, size)` stamp in the
  injected `FreshnessGuard`, keyed by the resolved path; write/edit use the
  same guard to refuse stale modifications.
- **Anchor** — relative `path` arguments resolve against the `WorkspaceAnchor`
  root; the absolute anchor root never leaks into model-visible output
  (results and messages echo the path as written).
- **Error split** — a missing file is `ToolReportedError` (recoverable; the
  model can correct course); a raised `RuntimeError` means the tool could not
  do its job (IO failure, overly large explicit range, invalid arguments).
- **Delegated reads** — with `fs=Some(...)`, content (and the existence
  check) ride the injected `WorkspaceFs`; the freshness stamp still comes
  from the process filesystem so write/edit comparisons are unaffected. The
  output contract is unchanged, and the default (`fs=None`) reads straight
  from the target filesystem.

`read` is **not** a search tool — use grep for content search and glob for
filename patterns; reading a whole large file page by page is the wrong shape
compared to grepping for the region first.
