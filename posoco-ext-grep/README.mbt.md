# posoco-ext-grep

> **Targets: native + js (bun)**

A `grep` content-search tool for
[Posoco](https://mooncakes.io/docs/colmugx/posoco) agents: searches for a
literal text pattern (not a regex) in files under a directory and returns
matching lines grouped by file with line numbers.

## Ports contributed

| Port | Contribution |
|------|--------------|
| `ToolProvider` | the `grep` tool, declared with `ExecutionPolicy::Parallel` |
| `Extension` | composes into `Agent(exts=[...])` as a tool extension |

## Usage

```bash
moon add colmugx/posoco-ext-grep
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-grep" @grep

let grep = @grep.GrepTools(anchor=Some(anchor))
let agent = @posoco.Agent(exts=[grep, ..other_extensions], config~)
```

`anchor` is optional: with an injected `WorkspaceAnchor` the search base
resolves against the workspace root and result paths are rebased back to the
argument spelling (no prefix when the base was the default `"."`), so the
workspace root never leaks into model-visible output; without one, the base
lands on the process working directory. `ignores` overrides the pruned
directory names (default: `@devkit.default_ignore_patterns()`).

## Engine ladder (js) and engine parity

Both engines share one contract: literal matching, hidden entries and
`ignores` directories pruned, binary-looking files skipped, `glob` filter
applied.

- **native** — in-process walker (`@fs.walk` + per-line `contains`),
  deterministic order, no external dependency.
- **js (bun)** — ripgrep first: PATH via `Bun.which`, then the common
  Homebrew prefixes; each candidate is validated by spawning `rg --version`
  and checking the banner, so a `grep` shim on PATH is rejected. Pinned
  flags: `--no-ignore` + negated `--glob` excludes (parity with the walker's
  ignore list — no `.gitignore` reading), NUL-separated output (safe against
  `:` in filenames), `-F` literal matching. When no real rg is found the
  same in-process walker runs over `node:fs`.

## Tool arguments

| Argument | Type | Description |
|----------|------|-------------|
| `pattern` | string, required | Literal text to search for (non-empty; not a regex) |
| `path` | string | Directory to search in (default `"."`) |
| `glob` | string | File filter; bare name pattern (e.g. `*.mbt`) matches the basename at any depth, a pattern containing `/` matches the base-relative path |
| `output_mode` | string | `content` (default), `files_with_matches`, or `count` |
| `case_insensitive` | bool | Match ignoring case (default false) |
| `max_matches` | int | Cap on returned entries — match lines (content) or files (other modes); default 100 |

## Behavior

- **Parallel execution** — read-only search, safe to run alongside other tools.
- **Uniform output across engines** — both engines return flat matches
  feeding one shared formatter. Content mode groups by file
  (`Found N matches in M files:` + one file header with `  L<n>: <line>`
  entries); `files_with_matches` lists paths; `count` lists `path:count`
  lines; zero results stay `No matches found for: <pattern>`. Structured
  payload (`summary`, `count`, `truncated`) for observers/UIs.
- **Bounded output** — 2000-character per-line truncation (matching read),
  a 100 KB body cap, and the `max_matches` entry cap; anything cut ends with
  a `… N more …` footer reporting the remainder.
- Search failures surface as model-visible errors with the sanitized base path
  (only the base itself failing is loud; unreadable or binary files are
  skipped silently, matching rg).
