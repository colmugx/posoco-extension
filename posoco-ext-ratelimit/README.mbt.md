# posoco-ext-ratelimit

\`posoco-ext-ratelimit\` watches typed provider quota/rate-limit verdicts and
automatically resumes the interrupted Posoco session after the provider's reset
deadline.

## Architecture

The extension is split into four responsibilities:

- **RateLimitGuard** — thin Posoco \`PipelineHook\` / \`Observer\` /
  \`Lifecycle\` adapter.
- **RecoveryPolicy / RecoveryState** — provider deadline, probe backoff,
  attempts and per-session recovery data.
- **RateLimitRuntime** — one \`Fuwaroid\` loop that owns all mutable recovery
  state. Hooks and workers can only communicate with it through messages.
- **Fuwaroid Supervisor** — owns one-shot timers and resume workers.

The old \`Semaphore(1)\` and periodic polling monitor are gone. Resume
serialization is a runtime invariant: at most one \`RecoveryTicket\` is
in-flight. Timers are one-shot and stale-safe through \`epoch + deadline\`
validation.

A failed Posoco turn persists its failed-turn transcript before the
\`TurnFailed\` observer boundary. The guard therefore records the quota verdict
first, but does not make that session recoverable until \`TurnFailed\` arrives.
This prevents recovery from racing the failed transcript checkpoint.

Verdicts with a reset timestamp resume at \`reset_at_ms + margin_ms\`. Verdicts
without a timestamp use exponential probe backoff from \`probe_interval_ms\`,
capped by \`max_probe_interval_ms\`. Attempts remain capped per session by
\`max_attempts\`.

## Wiring

Preferred 0.4 API:

\`\`\`mbt nocheck
let guard = @ratelimit.RateLimitGuard()
let agent = @posoco.Agent(
  exts=[guard, model_ext, io_ext],
  config,
)

@async.with_task_group(group => {
  guard.start(group~, agent~)

  // run the host / agent here

  guard.shutdown()
})
\`\`\`

\`start(group~, agent~)\` binds the Posoco executor and starts both the Fuwaroid
state loop and its Supervisor.

For compatibility, the old two-step wiring remains available:

\`\`\`mbt nocheck
guard.bind(agent)
guard.spawn_monitor(group)
\`\`\`

Despite the old name, \`spawn_monitor\` no longer starts a polling loop; it is a
wrapper around the event-driven runtime.

## Snapshot and control

\`\`\`mbt nocheck
let pending = guard.snapshot()
guard.cancel_pending()
guard.shutdown()
\`\`\`

\`snapshot()\` is async because actor-owned state is never exposed by alias.
The ask also acts as a FIFO barrier for previously sent hook/observer events.

\`poll()\` remains as a compatibility seam for hosts that used to drive the
scheduler manually. It does not scan in a background loop; it only asks the
actor to dispatch work that is already due at the injected clock.

## Concurrency guarantees

- all \`RecoveryState\` mutation happens in one Fuwaroid command fold;
- async timer/resume workers never mutate business state directly;
- stale worker results are ignored by \`RecoveryTicket(epoch)\`;
- \`cancel_pending()\` advances the epoch and invalidates pending/in-flight
  recovery;
- only one resume worker can be in-flight per runtime;
- shutdown closes the actor and uses \`Supervisor::shutdown\` for bounded
  cancellation/settlement.

Requires a modelport that classifies quota failures as typed
\`ModelError::RateLimited\`.
