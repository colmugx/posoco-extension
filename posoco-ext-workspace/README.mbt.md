# posoco-ext-workspace

A small workspace-boundary extension for Posoco coding agents.

The initial release provides:

- a stable workspace root;
- lexical resolution of relative paths;
- rejection of absolute paths, drive-prefixed paths, and `..` escapes;
- a `SystemPromptContributor` describing the active project boundary;
- direct composition through Posoco's `Extension` API.

```moonbit
let workspace = match Workspace::new("/repo") {
  Ok(value) => value
  Err(reason) => abort(reason)
}

let path = workspace.resolve("src/main.mbt")
```

## Security boundary

`Workspace::resolve` is intentionally lexical. Filesystem adapters must still canonicalize the resolved path and verify symlinks before performing I/O. This package establishes the shared policy contract; it does not claim that string normalization alone is a complete sandbox.
