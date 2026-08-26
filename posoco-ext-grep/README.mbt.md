# posoco-ext-grep

> **Targets: native + js (bun)**

A `grep` content-search tool for
[Posoco](https://mooncakes.io/docs/colmugx/posoco) agents: searches for a
text pattern in files under a directory and returns matching lines as
`path:line:content` entries.

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
lands on the process working directory.

## Tool arguments

| Argument | Type | Description |
|----------|------|-------------|
| `pattern` | string, required | Text pattern to search for |
| `path` | string | Directory to search in (default `"."`) |
| `glob` | string | File pattern filter (e.g. `*.mbt`) |

## Behavior

- **Parallel execution** — read-only search, safe to run alongside other tools.
- **Uniform output across engines** — both searchers return
  `path:line:content` entries feeding one shared formatter: `Found N matches:`
  followed by one entry per line, or `No matches found for: <pattern>`;
  plus a structured payload (`summary`, `count`) for observers/UIs.
- Search failures surface as model-visible errors with the sanitized base path.
