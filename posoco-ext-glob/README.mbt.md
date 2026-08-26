# posoco-ext-glob

> **Targets: native + js (bun)**

A `glob` file-search tool for
[Posoco](https://mooncakes.io/docs/colmugx/posoco) agents: walks a directory
tree and returns paths matching a glob-like pattern. Supports `*` (any
characters within one segment) and `**` (recursive) — e.g. `**/*.mbt` finds
all `.mbt` files recursively.

## Ports contributed

| Port | Contribution |
|------|--------------|
| `ToolProvider` | the `glob` tool, declared with `ExecutionPolicy::Parallel` |
| `Extension` | composes into `Agent(exts=[...])` as a tool extension |

## Usage

```bash
moon add colmugx/posoco-ext-glob
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-glob" @glob

let glob = @glob.GlobTools(anchor=Some(anchor))
let agent = @posoco.Agent(exts=[glob, ..other_extensions], config~)
```

`anchor` is optional: with an injected `WorkspaceAnchor` the scan base
resolves against the workspace root and results are re-anchored relative to
it, so the workspace root never leaks into model-visible output; without
one, the base lands on the process working directory.

## Tool arguments

| Argument | Type | Description |
|----------|------|-------------|
| `pattern` | string, required | Glob pattern (e.g. `**/*.mbt`, `src/*.mbt`) |
| `path` | string | Base directory to search (default `"."`) |

## Behavior

- **Parallel execution** — read-only scan, safe to run alongside other tools.
- **Uniform output across engines** — both scanners feed one shared
  formatter: `Found N files:` followed by one path per line, plus a
  structured payload (`summary`, `count`) for observers/UIs.
- Scan failures surface as model-visible errors with the sanitized base path.
