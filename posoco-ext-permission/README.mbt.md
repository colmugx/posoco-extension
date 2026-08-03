# posoco-ext-permission

A composable `PreToolHook` permission policy for Posoco coding agents.

## Modes

- `ReadOnly`: approves `read`, `grep`, and `glob`; rejects mutation, shell, and unknown tools.
- `WorkspaceWrite`: approves known read and write tools; defers shell and unknown tools to the host.
- `Interactive`: approves inspection and defers all side-effecting or unknown tools.

```moonbit
let permissions = PermissionPolicy::new(Interactive)
let agent = Agent::Agent(
  exts=[permissions, ..other_extensions],
  config~,
)
```

`Defer` is intentionally used instead of embedding a terminal UI into this package. The host decides how to request confirmation through its `UiPort` or another control surface.

The initial policy classifies standard coding-tool names. Follow-up work should add argument-aware shell classification, workspace-aware path checks, provider namespaces, and user-defined rules.
