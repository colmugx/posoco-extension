# posoco-ext-memoh

Memoh host adapter for Posoco agents.

This package owns behavior that exists specifically because an agent is hosted
by Memoh. Product binaries such as `cetas-memoh` compose it; they should not
reimplement Memoh-specific session, context, MCP, approval, memory, or steering
semantics themselves.

## Foundation contract

The first public surface is an intentionally ephemeral `SessionStore`:

- `load` always returns an empty Posoco session;
- `save`, `append_messages`, and `truncate` are explicit no-ops;
- no conversation transcript is persisted by this extension.

Memoh remains the durable conversation authority and supplies host context for
each turn. This prevents a Memoh conversation and a local Posoco transcript
from becoming two competing sources of truth.

```moonbit
let memoh = @memoh.Memoh()
let agent = @posoco.Agent(
  exts=[memoh, ..other_extensions],
  config~,
)
```

## Planned host surfaces

The same `Memoh` extension will grow the Memoh-specific integration points:

- current-turn embedded context;
- Memoh ACP client contract validation;
- Memoh Tools MCP discovery and safe transport configuration;
- host-specific lifecycle and diagnostics;
- later, memory and steering enhancements.

Generic ACP protocol behavior does not belong here and stays in
`posoco-ext-acp`.

## License

Apache-2.0
