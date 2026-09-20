# posoco-ext-write

[write tool for Posoco agents](https://mooncakes.io/docs/colmugx/posoco) —
writes a whole file as a `ToolProvider`: create-or-truncate, automatic parent
directories, atomic replace via a sibling temp file + rename.

> **Targets: native + js** — native writes through `@fs`; js writes through
> node:fs sync APIs. On wasm/wasm-gc the tool is not listed and `execute`
> raises `InvocationFailed`.

## Ports contributed

| Port | Contribution |
|---|---|
| `ToolProvider` | the `write` tool |

## Usage

```bash
moon add colmugx/posoco-ext-write
```

```moonbit nocheck
// moon.pkg: "colmugx/posoco-ext-write" @write

// Share one guard/anchor with the read/edit tools so freshness and relative
// paths agree across the file tools (composition from cetas-core's
// build_default_features):
let freshness = @devkit.FreshnessGuard::FreshnessGuard()
let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor(ctx.cwd)
let exts : Array[&@posoco.Extension] = [
  @write.WriteTools(freshness~, anchor=Some(anchor)),
  // ... other extensions ...
]
let agent = Agent(exts=exts, config~)
```

`WriteTools::WriteTools(freshness?, anchor?)` takes all arguments optional:
without a `FreshnessGuard` the read-before-modify gate is disabled and blind
overwrites succeed; without an `anchor` relative paths resolve against the
process working directory. `write_extension()` is a zero-config factory for
hosts that want neither.

## Tool arguments

| Argument | Type | Meaning |
|---|---|---|
| `path` | string, required | file to write |
| `content` | string, required | full replacement text |

## Behavior notes

- **Freshness gate** — overwriting an existing file requires that it was read
  earlier in the same agent (via the shared `FreshnessGuard`) and has not
  changed since. A violation is a `ToolReportedError` (`write: refused: …`),
  so the model can re-read and retry instead of losing the turn. A successful
  write re-records the stamp, so the immediately following edit is not
  blocked by the write itself.
- **Atomic write** — content lands through a sibling temp file renamed over
  the target; parent directories are created recursively; a failed rename
  removes the temp file so no partial state is left behind.
- **Size cap** — content over 1,000,000 UTF-8 bytes is refused with a
  `ToolReportedError` and the target is left untouched.
- **Honest byte counts** — success reports UTF-8 bytes
  (`Wrote N bytes to <path>`), not code units.
- **Anchor** — relative paths resolve against the `WorkspaceAnchor` root and
  key the freshness ledger canonically, so overwriting through a different
  relative spelling still passes the gate; results echo the path as written
  and diagnostics are sanitized to a bounded single line.
- **Exclusive policy** — the tool declares `ExecutionPolicy::Exclusive`.
- **Error split** — refusals (unread or stale file, oversize content) are
  model-visible `ToolReportedError`s; missing or wrongly typed arguments and
  IO failures raise `RuntimeError`.

`write` is for new files or complete rewrites — it is **not** a targeted
edit; use edit for in-place changes.
