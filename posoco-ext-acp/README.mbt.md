# posoco-ext-acp

[Agent Client Protocol](https://agentclientprotocol.com/) (ACP) **v1** bridge
for [Posoco](https://github.com/colmugx/posoco) agents, built on the
[`colmugx/acp`](https://github.com/colmugx/acp.mbt) MoonBit SDK.

One extension turns a Posoco agent into an ACP agent:

- **`Observer`** — projects turn events (`ToolCallPending`, `ToolCallResult`,
  `ModelResponseReceived`, stream deltas, ...) onto ACP `session/update`
  notifications (`ToolCall`, `ToolCallUpdate`, `AgentMessageChunk`,
  `AgentThoughtChunk`, `UsageUpdate`).
- **`Hook::before_tool`** — gates every tool call through an ACP
  `session/request_permission` reverse request, so editors such as Zed render
  their native approval UI. Permission transport failures fail closed.
- **`Lifecycle::on_shutdown`** — releases the attached session.

This package owns only the Posoco-side adaptation. The ACP endpoint, stdio
runtime, and session lifecycle belong to the host (a future
**cetas-acp** composes `agent_spec` / `agent_serve_stdio_with_outbound` from
`colmugx/acp` with `Agent(exts=[...])` from Posoco and wires the two through
this bridge). `colmugx/acp` itself stays independent of Posoco by design.

## Installation

```bash
moon add colmugx/posoco-ext-acp
```

```text
import {
  "colmugx/posoco-ext-acp"
}
```

## Usage

The host attaches the acp.mbt `AgentContext` (plus the ACP session id) when
a session/prompt turn starts and reads the bridge back at turn end. While
detached, the bridge is inert: it approves every tool and drops every event.

```moonbit nocheck
///|
async fn acp_prompt_turn(
  bridge : @ext_acp.AcpBridge,
  context : @acp.AgentContext,
  session_id : String,
  agent : @posoco.Agent,
  prompt : Array[@acp.ContentBlock],
) -> @acp.PromptResult {
  bridge.attach(context~, session_id~)
  let _ = agent.run_turn(to_posoco_message(prompt), session_id)
  ignore(bridge.flush()) // deliver everything still queued
  match bridge.take_failure() {
    Some(_) => ... // fail the session/prompt response
    None => ()
  }
  { stop_reason: bridge.stop_reason(), meta: Omitted }
}
```

Compose it like any Posoco extension:

```moonbit nocheck
///|
let bridge = @ext_acp.AcpBridge(
  needs_permission=call =>
    @ext_acp.acp_tool_kind(call.name.to_string()) is not @acp.ToolKind::Read, // e.g. ask for everything but reads
)
let agent = @posoco.Agent(
  exts=[bridge],
  config=agent_config,
)
```

For live token streaming, run the concurrent pump in a task group and keep
`flush` for turn-end determinism — both drains coexist and every queued
update is delivered exactly once:

```moonbit nocheck
///|
@async.with_task_group(group => {
  bridge.spawn_pump(group)
  // ... run turns ...
  bridge.close() // pump exits once the queue closes
})
```

## Wire mapping (ACP v1)

| Posoco event | ACP `session/update` |
|---|---|
| `ToolCallPending` | `ToolCall` (status `Pending`, kind, title, raw input) |
| `ToolCallResult` | `ToolCallUpdate` (status `Completed`/`Failed`, text content) |
| `ToolCallDeferred` | `ToolCallUpdate` (status `Pending`, deferred title) |
| `StreamChunkReceived(TextDelta/ReasoningDelta)` | `AgentMessageChunk` / `AgentThoughtChunk` sharing one per-round `messageId` |
| `ModelResponseReceived` | full `AgentThoughtChunk` + `AgentMessageChunk` (suppressed when the same text/thought already streamed this round) + cumulative `UsageUpdate` |
| `TurnFailed` | recorded for the host — v1 has no error-chunk update; turn errors belong on the `session/prompt` response |

Tool kind is derived from the tool name (`read`/`grep`/`bash`/... plus
compound names and `server__tool` namespaces); titles read
`name(primary-arg)` with sanitized, single-line operands.

## Versioning

Targets **ACP v1** — exactly what `colmugx/acp` implements today. When the
SDK ships v2, this extension upgrades with it and deletes the v1-only
behavior; there is no compatibility layer and no legacy path.

## License

Apache-2.0
