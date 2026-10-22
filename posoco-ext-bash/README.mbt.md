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
