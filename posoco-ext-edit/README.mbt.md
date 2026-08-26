# posoco-ext-edit

> **Targets: native + js (bun)**

An exact-string-replacement `edit` tool for
[Posoco](https://mooncakes.io/docs/colmugx/posoco) agents. On wasm/wasm-gc
the tool is not listed and execution raises `InvocationFailed`.

## Match contract

`old_text` must match the file content exactly and — unless
`replace_all: true` is set — uniquely:

- **0 matches** → model-visible error suggesting a fresh read.
- **>1 matches** → error listing the matching line numbers (up to five),
  telling the model to add surrounding context or pass `replace_all`.

Line-number prefixes (`L12: `) that the model copied verbatim from read
output are stripped automatically — but only as a whole block, and only when
the raw text does not match. This is format hygiene for our own read output,
not fuzzy matching.

## Tool arguments

| Argument | Type | Description |
|----------|------|-------------|
| `path` | string, required | File to edit |
| `old_text` | string, required | Exact text to find |
| `new_text` | string, required | Replacement text |
| `replace_all` | boolean | Replace every occurrence (default false; a non-unique match without this flag is an error) |

## Behavior

- **Freshness gate** — shares the host-injected `FreshnessGuard` ledger with
  the read/write tools: the file must have been read this session and must
  not have changed since, otherwise the edit is refused with a recoverable
  `ToolReportedError`. After a successful edit the stamp is re-recorded, so
  an immediate follow-up edit of the same file is not blocked by its own
  change.
- **Workspace anchor** — with an injected `WorkspaceAnchor`, relative paths
  resolve against the workspace root; results echo the path as written so
  the anchor root never leaks into tool output.
- **Atomic write** — temp file + rename on every target.
- **Exclusive execution** — declared with `ExecutionPolicy::Exclusive`.
- Success messages report the replacement count and line numbers.

## Usage

```bash
moon add colmugx/posoco-ext-edit
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-edit" @edit

// Share one FreshnessGuard across read/write/edit; anchor is optional.
let edit = @edit.EditTools(freshness=Some(guard), anchor=Some(anchor))
let agent = @posoco.Agent(exts=[edit, ..other_extensions], config~)
```

Both options are optional: `freshness=None` disables the gate (library use)
and `anchor=None` resolves relative paths against the process working
directory.
