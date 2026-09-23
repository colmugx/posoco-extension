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
