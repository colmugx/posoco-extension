# posoco-ext-astgrep

> **Targets: native + js (bun)**

An `astgrep` structural code-search tool for
[Posoco](https://mooncakes.io/docs/colmugx/posoco) agents: matches code by
its syntactic shape using ast-grep patterns with meta-variables
(`$NAME`, `$$$BODY`), powered by the [ast-grep](https://ast-grep.github.io)
CLI. This is **not** literal/regex text search — that is the
`posoco-ext-grep` extension's job.

## Ports contributed

| Port | Contribution |
|------|--------------|
| `ToolProvider` | the `astgrep` tool, declared with `ExecutionPolicy::Parallel` |
| `Extension` | composes into `Agent(exts=[...])` as a tool extension |

## Usage

```bash
moon add colmugx/posoco-ext-astgrep
```

```moonbit nocheck
// moon.pkg: "colmugx/posoco-ext-astgrep" @astgrep

let astgrep = @astgrep.AstGrepTools(anchor=Some(anchor))
let agent = @posoco.Agent(exts=[astgrep, ..other_extensions], config~)
```

`anchor` is optional: with an injected `WorkspaceAnchor` the search base
resolves against the workspace root (default base: the root itself) and the
child process runs with the root as its working directory; without one, the
base lands on the process working directory.

## Requirements

The `ast-grep` binary must be installed; both the `ast-grep` and `sg` names
are accepted (`brew install ast-grep`). Each execute probes candidates —
PATH first, then the common Homebrew prefixes — and validates each one by
spawning `--version` and checking the banner, so a look-alike shim on PATH
is rejected. When no real binary is found, `execute` raises
`RuntimeError::InvocationFailed` with the tried candidates and the install
hint (the tool stays listed; `list_tools` is synchronous and does not
probe).

## Tool arguments

| Argument | Type | Description |
|----------|------|-------------|
| `pattern` | string, required | ast-grep pattern with meta-variables (e.g. `fn $NAME($$$ARGS) { $$$BODY }`) |
| `lang` | string | Tree-sitter language id (e.g. `ts`, `py`); inferred per file when omitted |
| `path` | string | Directory or file to search (default `.`) |
| `glob` | string | File filter, e.g. `*.ts` or a glob list like `*.ts,*.js` |
| `max_matches` | integer | Maximum returned matches; default 100 |

## Behavior

- **Parallel execution** — read-only search, safe to run alongside other tools.
- **Output contract** — search runs with ast-grep's documented `--json=stream` mode. Each match is rendered as a compact file header plus `line|excerpt`; line numbers are 1-based, multi-line matches are flattened, and each excerpt is capped at 500 characters.
- **Bounded results** — at most `max_matches` entries are shown (default 100) and the rendered body is capped at 32 KB. Truncation uses a short `… +N matches` footer. Unexpected JSON falls back to bounded raw output instead of becoming an unbounded result.
- **Bounded errors** — non-zero exits return `astgrep exit=N path=...` plus at most 4,000 characters of stderr/stdout. Empty successful output is simply `(no matches)`.
- **Validation before spawn** — a missing or wrong-typed `pattern` returns a
  `ToolReportedError` with a fix hint naming the expected shape; no process
  is spawned.
- **Differences from posoco-ext-grep** — matches AST structure via ast-grep
  patterns instead of literal text; requires the external ast-grep binary on
  both native and js (the grep extension's in-process walkers have no
  ast-grep counterpart here); supports `lang` for per-language matching and
  has no `output_mode`/`case_insensitive` knobs.
