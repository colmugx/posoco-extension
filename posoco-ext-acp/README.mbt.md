# posoco-ext-acp

[Agent Client Protocol](https://agentclientprotocol.com/) (ACP) **v1** bridge
for [Posoco](https://github.com/colmugx/posoco) agents, built on the
[`colmugx/acp`](https://github.com/colmugx/acp.mbt) MoonBit SDK. One
extension turns a Posoco agent into an ACP agent that editors such as Zed
can drive natively.

## Ports contributed

One `AcpBridge` struct implements four public Posoco ports over shared state:

| Port | Contribution |
|------|--------------|
| `Observer` | Projects turn events onto ACP `session/update` notifications (see wire mapping below) |
| `ApprovalSource` | Translates `posoco-ext-permission` approval asks into ACP `session/request_permission` reverse requests — pure protocol translation |
| `UiPort` | Maps interactive requests onto ACP v1 `elicitation/create` form-mode requests (the channel ask-question-style tools ride) |
| `Lifecycle` | Releases the attached session on shutdown |

Which tools ask for permission is NOT the bridge's concern: compose a
`@permission.PermissionPolicy` and hand it the bridge as its approval source.
While detached the bridge is inert — every approval ask returns `AllowOnce`
(nothing is remembered) and every event is dropped. A permission transport
failure fails closed: the tool never executes without an explicit client
allow.

## Usage

```bash
moon add colmugx/posoco-ext-acp
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-acp" @ext_acp

let bridge = @ext_acp.AcpBridge()
// The policy owns modes, tool classification, and session caching;
// the bridge translates each ask into a request the editor renders.
let policy = @permission.PermissionPolicy(
  @permission.Interactive,
  approval=Some(bridge as &@permission.ApprovalSource),
)
let agent = @posoco.Agent(exts=[bridge, policy, ..other_extensions], config~)
```

Interactive UI consumers (e.g. posoco-ext-askquestion) take the bridge's
`UiPort` view: `Input` / `Confirm` / `Select` become elicitation form fields;
a client without the elicitation capability raises `Unsupported`, which such
tools degrade to a model-visible tool error instead of failing the turn.

```moonbit nocheck
let ask = @askquestion.AskQuestionTools(bridge as &@posoco.UiPort)
```

### Per-prompt turn loop

The host attaches the acp.mbt `AgentContext` plus ACP session id when a
prompt turn starts and reads the bridge back at turn end:

```moonbit nocheck
///|
@async.with_task_group(group => {
  bridge.spawn_pump(group) // real-time streaming drain
  bridge.attach(context~, session_id~)
  let _ = agent.run_turn(to_posoco_message(prompt), session_id)
  ignore(bridge.flush()) // deterministic turn-end drain
  bridge.close() // pump exits once the queue closes
})
match bridge.take_failure() {
  Some(_) => ... // fail the session/prompt response
  None => ()
}
{ stop_reason: bridge.stop_reason(), meta: Omitted }
```

Both drains coexist and every queued update is delivered exactly once; the
next `attach` reopens a fresh queue, so this scope repeats per prompt.

## Wire mapping (ACP v1)

| Posoco event | ACP `session/update` |
|---|---|
| `ToolCallPending` | `ToolCall` (status `Pending`, kind, title, raw input) |
| `ToolCallResult` | `ToolCallUpdate` (status `Completed`/`Failed`, text content) |
| `ToolCallDeferred` | `ToolCallUpdate` (status `Pending`, deferred title) |
| `StreamChunkReceived(TextDelta/ReasoningDelta)` | `AgentMessageChunk` / `AgentThoughtChunk` sharing one per-round `messageId` |
| `ModelResponseReceived` | full `AgentThoughtChunk` + `AgentMessageChunk` (suppressed when the same text/thought already streamed this round) + cumulative `UsageUpdate` |
| `TurnFailed` | recorded for the host (`take_failure`) — v1 has no error-chunk update; turn errors belong on the `session/prompt` response |

Tool kind is derived from the tool name (`read`/`grep`/`bash`/... plus
compound names and `server__tool` namespaces); titles read
`name(primary-arg)` with sanitized, single-line operands.

## Scope

This package owns only the Posoco-side adaptation. The ACP endpoint, stdio
runtime, and session lifecycle belong to the host (a future **cetas-acp**
composes `agent_spec` / `agent_serve_stdio_with_outbound` from `colmugx/acp`
with `Agent(exts=[...])` from Posoco and wires the two through this bridge).
`colmugx/acp` itself stays independent of Posoco by design.

Targets **ACP v1** — exactly what `colmugx/acp` implements today. When the
SDK ships v2, this extension upgrades with it and deletes the v1-only
behavior; there is no compatibility layer and no legacy path.

## License

Apache-2.0
