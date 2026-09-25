# posoco-ext-memoh

Memoh host adapter for Posoco agents.

This package owns behavior that exists specifically because an agent is hosted
by Memoh. Product binaries such as `cetas-memoh` compose it; they should not
reimplement Memoh-specific session, context, MCP, approval, memory, or steering
semantics themselves.

## Foundation contract

The `Memoh` value is an intentionally ephemeral `SessionStore`: `load`
always returns an empty Posoco session and `save`, `append_messages`, and
`truncate` are explicit no-ops. Memoh remains the durable conversation
authority.

## Client and current-turn context

The adapter requires `initialize.clientInfo.name == "memoh"` and decodes the
canonical host resource:

```text
URI:  memoh://context/current-turn
MIME: text/markdown
```

Host context and user text/images remain separate. `Memoh::prepare_turn`
installs the host context for the current turn; `PipelineHook::before_model`
injects it as a dedicated system-level host-context message, and turn-end
cleanup prevents context bleed.

## ACP Agent support

`memoh_agent_support()` declares the capabilities a first-class Memoh runtime
advertises in its ACP initialize response: image prompts, embedded context, and
HTTP MCP. These are AgentCapabilities, not Memoh ClientCapabilities.

## Memoh Tools MCP

`memoh_tools_mcp_config` selects the injected `Memoh Tools` HTTP server,
accepts the `Memoh_Tools` alias, forwards host-scoped headers without logging
their values, and ignores unrelated ACP MCP declarations. Missing, duplicate,
stdio, or SSE Memoh Tool Gateway declarations fail closed.

## Permission authority

`MemohApprovalSource` delegates the real approval request but demotes
`AllowSession` and `AllowAlways` to `AllowOnce`, preventing Posoco from
creating a second standing authorization cache.

Generic ACP protocol behavior remains in `posoco-ext-acp`; Memoh-specific
behavior belongs here.

## License

Apache-2.0
