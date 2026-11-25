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

Line-number prefixes from current `12|text` or legacy `L12: text` read
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

## Multiple replacements in one file

For 2–20 related changes to the same file, pass `path` and an ordered
`hunks` array instead of top-level `old_text`, `new_text`, and
`replace_all`. Each hunk uses the same exact-match contract:

```json
{"path":"src/main.mbt","hunks":[{"old_text":"old_a","new_text":"new_a"},{"old_text":"old_b","new_text":"new_b"}]}
```

The file is read once after the existing freshness check. Hunks run in
memory in order (later hunks see earlier replacements). If any hunk is
missing or ambiguous, no write occurs and the error identifies the hunk.
Only a fully planned batch is written atomically. The existing single-hunk
form and its result format remain unchanged. Batch metadata reports total
matches, line numbers relative to each hunk's input state, and whether any
read prefix was stripped. A batch still edits exactly one file.

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
- **Compact success** — model-visible success is `ok: N lines=...`; detailed
  count/line data and whether copied read prefixes were stripped are also
  available in structured metadata.

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
