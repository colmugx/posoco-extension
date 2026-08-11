# Posoco integration requirement

`posoco-ext-continuity` needs the current `RunId` and `SessionId` at model and tool execution boundaries. Posoco already owns these canonical identities; the extension only needs them forwarded through the public ports.

## Required API additions

Add backwards-compatible scoped variants to `ModelPort` and `ToolProvider`.

Conceptually:

```moonbit
async fn ModelPort::chat_scoped(
  Self,
  run_id : @kernel.RunId,
  session_id : @kernel.SessionId,
  messages : Array[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  options : @types.ChatOptions,
  stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError
```

The default implementation must delegate to the existing `chat(...)`, so existing ModelPort implementations remain source-compatible.

```moonbit
async fn ToolProvider::execute_scoped(
  Self,
  run_id : @kernel.RunId,
  session_id : @kernel.SessionId,
  requested_name : String,
  call : @kernel.ToolCall,
) -> @kernel.ToolOutcome
```

The default implementation must delegate to the existing `execute(...)`.

## Runtime wiring

Forward the `RunId` and `SessionId` already owned by the run through the HostRuntime / PortRuntime execution path so that:

- model effects call `chat_scoped(...)`;
- tool effects call `execute_scoped(...)`;
- existing ports that do not override scoped methods behave exactly as before.

Do not put session identity in `ChatOptions`, model-visible tool arguments, globals, or thread-local state.

## Why Continuity needs this

Continuity state is session-owned. `session_checkpoint`, `session_history_search`, and `session_history_read` must always operate on the host-selected current session. The model must never be allowed to choose another session by supplying an ID in tool arguments.

`RunId` is also needed to reject stale checkpoint candidates created by an earlier overlapping run.

## Non-goals

This change does not add Continuity logic to Posoco. Posoco only forwards identities it already owns. Checkpoint planning, archive storage, retrieval, and prompting remain extension concerns.
