# posoco-ext-ratelimit

Records provider quota verdicts (HTTP 429 with a stated reset time) per
session and auto-resumes the interrupted turn when the reset time arrives.

Coding-plan providers (Claude, Codex, z.ai GLM, …) throttle with 429 and a
reset hint. Posoco modelports raise the typed
`ModelError::RateLimited(RateLimitInfo)` for those verdicts; this extension
watches them, remembers `{session, reset time, interrupted input}`, and at
reset time re-runs the turn on the same session id with the same model
selection. A turn that dies on 429 persists nothing to the session store
(posoco saves only completed turns), so resending the original input cannot
duplicate anything.

Verdicts with a stated reset time resume at that time (plus `margin_ms`).
Verdicts without one — Kimi's "quota will be refreshed in the next period",
whose only documented wait signal is the `Retry-After` header when the
provider sends it — fall back to probing: retry after `probe_interval_ms`
(default 15 min), doubling per attempt up to 1 hour. Set
`probe_interval_ms=0` to ignore unschedulable verdicts entirely. Resumes
are capped per session (`max_attempts`, default 3); a successful turn
clears the counter.

## Wiring

```mbt nocheck
let guard = @ratelimit.RateLimitGuard()
let agent = @posoco.Agent(exts=[guard, model_ext, io_ext], config)
guard.bind(agent)
// MoonBit async has no detached spawn: the monitor lives in the host's
// task group (same pattern as posoco-ext-acp's spawn_pump).
@async.with_task_group(group => guard.spawn_monitor(group))
```

Hosts that already run a periodic loop can call `guard.poll()` from it
instead of spawning the monitor. `pending_snapshots()` exposes the current
schedule for status UIs.

Requires a modelport that classifies 429 as `ModelError::RateLimited` —
posoco-ext-zai, posoco-ext-openai-compatible and posoco-ext-kimi do; others
adopt the shared classifier in posoco-kit-chat-completions.
