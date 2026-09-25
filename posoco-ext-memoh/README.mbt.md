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

## Memoh client and turn context

The adapter validates the ACP client identity (`clientInfo.name == "memoh"`)
and decodes Memoh's canonical embedded context resource:

```text
URI:  memoh://context/current-turn
MIME: text/markdown
```

`decode_memoh_prompt` keeps that host context separate from user text/images.
`Memoh::prepare_turn` installs the host context for the current turn and
returns only the real Posoco `UserMessage`. The extension's
`PipelineHook::before_model` injects a dedicated system-level host-context
message after any stable system prompt, and `on_turn_end` clears it so
context cannot bleed into the next turn.

Other ACP block kinds are rejected instead of silently changing their
authority or semantics.

## Memoh Tools MCP

`memoh_tools_mcp_config` selects the host-injected `Memoh Tools` HTTP MCP
declaration from ACP `session/new`, accepts the `Memoh_Tools` slug alias,
and converts it to a `posoco-ext-mcp` server config.

The adapter forwards all non-empty HTTP headers in declaration order without
logging their values. Unrelated ACP MCP declarations are ignored: Memoh itself
is the federation and policy authority, so a Memoh-specific agent does not
open an independent MCP path around the Tool Gateway. The internal server name
is normalized to `Memoh_Tools` so Posoco's namespaced tool identifiers remain
provider-safe.

Missing Memoh Tools or a stdio/SSE declaration fails closed.

## Permission authority

`MemohApprovalSource` wraps the normal approval source used by a Posoco
`PermissionPolicy`. The wrapped source still performs the actual host
approval request, but `AllowSession` and `AllowAlways` are deliberately
demoted to `AllowOnce`.

That prevents Posoco's normal agent-lifetime approval cache from becoming a
second authorization authority. Memoh remains responsible for each relevant
permission decision and for the exact lifetime/scope of any grant it issues.

## Planned host surfaces

The same `Memoh` extension will continue to grow host-specific diagnostics,
memory, and steering enhancements.

Generic ACP protocol behavior does not belong here and stays in
`posoco-ext-acp`.

## License

Apache-2.0
