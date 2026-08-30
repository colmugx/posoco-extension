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

### One bridge, one session

A bridge is bound to one ACP session for its whole life; `session_id()`
reads the binding and returns `None` while detached. Re-attaching the bound
session id is idempotent, so hosts may attach once per session or once per
prompt turn: each attach refreshes the bound `AgentContext`, clears
`last_failure`, resets the in-round streaming state, and reopens a closed
queue. `used_tokens` (ACP usage is session-cumulative) and `message_seq`
(minted message ids stay unique) deliberately persist across prompts.

Attaching a different session id while bound aborts with a diagnostic —
cross-session wiring must fail loudly instead of mislabeling updates, so
run one bridge per session. `close()` only closes the outbound queue (a
running pump drains and exits; events enqueued while closed are dropped);
it does not unbind. `detach()` is the only unbind exit — after it the
bridge may be rebound — and `Lifecycle::on_shutdown` performs `close()` +
`detach()`. Items still queued at detach with no pump running stay queued
and are stamped with the next attached session; run `flush` first if
pending updates must reach the old client.

### The `_meta` decorator seam

The constructor accepts an optional decorator,
`meta~ : ((TurnEvent, SessionUpdate) -> Json?)?`. It is consulted exactly
once per queued update, at projection time, with the triggering turn event
and the projected update in hand; the send paths (`flush`, `spawn_pump`)
forward what projection decided and never re-derive it. `Some(json)` is
sent as the frame's `_meta`, `None` omits it — no decorator behaves
exactly like the undecorated wire, and the decorator has no explicit-null
concept. Typical use is injecting host-specific metadata (usage
provenance, say) onto frames; this package defines no concrete `_meta`
schema.

```moonbit nocheck
let bridge = AcpBridge(
  meta=Some(
    (
      event : @posoco.TurnEvent,
      _update : @acp.SessionUpdate,
    ) =>
      match event {
        ModelResponseReceived(usage=Some(u)) => Some(usage_to_host_meta(u))
        _ => None
      },
  ),
)
```

Two MoonBit realities the call site above bakes in: the caller wraps the
closure in `Some(...)` (the parameter itself is optional), and a
multi-parameter closure needs explicit parameter type annotations.

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

## Host adapters

Two plain struct adapters expose the ACP agent-to-client reverse calls for
host tool layers: `AcpTerminal` (`terminal/*`) and `AcpHostFs` (`fs/*`).
They implement no posoco port and never appear in an extension manifest —
the host (cetas-acp) consumes them directly. Each instance binds one
`AgentContext` plus one ACP session id (stamped on every reverse request)
and must not be reused across sessions.

### AcpTerminal

`AcpTerminal::run(command, cwd~, on_output?, timeout_ms?)` drives one
command to completion over `terminal/create` → `terminal/output` polling →
`terminal/wait_for_exit` → `terminal/release`. In v1 the command rides
`terminal/create` itself and `cwd` must be an absolute path — enforced by
the acp.mbt SDK's wire encoding, not normalized here. `terminal/output`
replies each carry the cumulative output captured so far, so `run` polls
and streams the diff between snapshots through `on_output` (after
host-side truncation the retained window is replayed as a best-effort
resync — v1's truncated flag cannot dedup precisely). `wait_for_exit`
supplies the authoritative exit code, then a final drain poll collects the
tail. `timeout_ms` bounds the whole run; absent means wait indefinitely.

`terminal/release` runs exactly once on every path; timeout and
cancellation first go through `terminal/kill`. A cancellation keeps its
identity (`TerminalCancelled`) and is never folded into a host failure.
`AcpTerminalResult` carries `exit_code` (absent when the command died by
signal) and the `output` captured at exit; `AcpTerminalError` is
`HostCallFailed(method_name~, cause~)`,
`TerminalTimedOut(timeout_ms~, partial_output~)`, or
`TerminalCancelled(partial_output~)`. Interactive terminals (start/feed/
drain on a live handle) are future work.

### AcpHostFs

`read_text_file(path~)` and `write_text_file(path~, content~)` pass
through to `fs/read_text_file` / `fs/write_text_file`. Path semantics
belong to the host, which resolves each path against the session cwd: the
adapter passes the string through verbatim — no normalization, no
existence check, no permission policy of its own (the host remains free to
deny any request). Reads request the whole file; the protocol's line/limit
window is not exposed. Failures are wrapped as
`AcpHostFsError::HostFsCallFailed(method_name~, cause~)` with the
underlying `AgentContextError` preserved.

## Scope

This package owns only the Posoco-side adaptation. The ACP endpoint, stdio
runtime, and session lifecycle belong to the host (**cetas-acp**
composes `agent_spec` / `agent_serve_stdio_with_outbound` from `colmugx/acp`
with `Agent(exts=[...])` from Posoco and wires the two through this bridge).
`colmugx/acp` itself stays independent of Posoco by design.

Targets **ACP v1** — exactly what `colmugx/acp` implements today. When the
SDK ships v2, this extension upgrades with it and deletes the v1-only
behavior; there is no compatibility layer and no legacy path.

## License

Apache-2.0
