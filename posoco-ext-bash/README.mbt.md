# posoco-ext-bash

Shell command ToolProvider for Posoco.

## Model-visible contract

- `bash` runs one `sh -c` command in a fresh shell. With a workspace anchor, the shell starts at that root; `cd` does not persist across calls.
- Successful short output is returned unchanged.
- Non-zero exits are `ToolReportedError` and start with `exit=N` so the model can distinguish a failing command even when it printed nothing.
- Model-visible output is capped at 32,768 characters. Truncated output keeps the first 4,096 characters and the tail, separated by `…[cut]…`; this preserves command context plus end-of-log diagnostics while bounding transcript growth.
- Invalid UTF-8 is a compact `ToolReportedError`: `bash: invalid UTF-8`.
- Process-launch/collection failures remain `RuntimeError::InvocationFailed`.

Both native and Bun execution paths use the same shared output formatter, so the cap and failure contract are target-consistent.

## Execution safety

- Each invocation has a hard wall-clock deadline of 300,000 ms by default, configurable with `timeout_ms` from 1 to 3,600,000 ms. This differs from the 2-second cancellation grace.
- Timeout returns `ToolReportedError` rather than success.
- Output pipes are drained while the child runs, with bounded retained data.
- A descendant retaining the output pipe does not keep the tool waiting indefinitely after the direct child exits.
- Foreground turn cancellation remains independent of command timeout.

True background sessions are not part of this patch. Background execution requires a host-owned task group with a lifetime beyond the tool call, session lookup, incremental logs, kill semantics and host-shutdown cleanup. Appending shell `&` is not equivalent.

## Host-owned background sessions (opt-in)

Existing `bash({"cmd":"echo hello"})` remains a normal foreground call. Background mode requires an explicit host task group that outlives individual tool invocations:

```moonbit
let bash = ShellTools()
@async.with_task_group(group => {
  bash.attach(group)
  // Host runs its tool/agent loop here. Call bash.shutdown() before returning.
})
```

`bash` accepts `background` (default false) and `yield_time_ms` (default zero, max 60000). The former starts a detached session; the latter waits briefly before returning a session for a long-running command. Both honor the hard `timeout_ms` deadline.

- `bash_status({"session_id":"...","cursor":0})`: read status and bounded incremental output.
- `bash_wait({"session_id":"...","timeout_ms":1000})`: bounded wait and return a snapshot.
- `bash_kill({"session_id":"..."})`: request termination.
- Sessions retain 32,768 output characters and include cursor/truncation information.
- Maximum 8 concurrently running and 32 retained sessions per provider; terminal sessions expire after 10 minutes.
- Silence for 60 seconds sets `suspected_stall=true` but does not prove deadlock.

The host's shutdown lifecycle cancels live workers. Session IDs are in-memory and are not restored across restarts.

Event notification (optional): pass a shared `@devkit.EventBus` to `ShellTools(bus=Some(bus))` and subscribe to `bash.session.started`, `bash.session.stall`, and `bash.session.finished`. Stall notifications are advisory; they do not kill a command automatically.
