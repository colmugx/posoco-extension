# posoco-ext-loop

A **session-scoped, fixed-interval recurring task scheduler** for Posoco.
This is different from the model/tool agent loop and different from
\`posoco-ext-goal\`: it schedules **ordinary, governed Posoco turns** at
user-selected intervals.

> Status: experimental (0.1.0). Jobs are **in memory only** and require an
> active host and agent scope. Nothing wakes when the host is shut down.

## Commands

\`\`\`text
/loop 5m check CI status
/loop 30s inspect the test output
/loop list
/loop pause loop_1
/loop resume loop_1
/loop stop loop_1
\`\`\`

Intervals: positive integers followed by \`s\`, \`m\`, \`h\`, or \`d\`,
between **1 second and 24 hours**. The task text is preserved; it is not
executed as shell code. At most 16 non-stopped jobs exist per Agent lifetime.

Only the user's \`CommandPort\` can create jobs. There is no model-visible
tool for scheduling perpetual work by default.

## Host integration

\`\`\`moonbit nocheck
let loop = @loop.LoopExtension()
let agent = @posoco.Agent(
  exts=[model_extension, session_extension, loop],
  config~,
  events=@posoco.EventSystem(),
)
@async.with_task_group(async fn(group) {
  loop.start(group~, agent~)
  agent.run_scoped(async fn(_agent) {
    agent.set_active_session(Some("session-id"))
    loop.set_session("session-id")
    // The host keeps this scope alive while it services commands.
    // For example, wait on its ordinary shutdown queue here.
  })
})
\`\`\`

Both \`start(group~, agent~)\` and \`set_session(id)\` are required; the
extension will report a command failure instead of silently accepting a job
when either is missing. The host must keep \`loop.set_session(id)\` synchronized
with the Agent's active UI session; clearing the binding suspends dispatch.

Commands may be invoked with a raw string or \`{"input": "5m check CI"}\` JSON.
The single \`input\` positional parameter is compatible with the Cetas JS
raw-remainder command adapter. Other hosts must forward the whole argument
rather than splitting the task into individual positional parameters.

## Scheduling semantics

- **Fixed delay**: the next interval begins after a completed or failed
  invocation. Missed ticks are not replayed.
- **Idle only**: each due job calls \`Agent::run_turn\`; Posoco's
  single-operation guard rejects concurrent user work with \`Busy\`.
  Busy is retried after 500ms and is not counted as a failure.
- **One in-flight invocation per job**: the actor moves it into \`running\`
  before spawning a supervised worker.
- **No cross-session execution**: jobs for other than the bound session remain
  dormant. Switching back delivers at most one overdue invocation.
- **Pause/stop** invalidate the pending scheduling generation. They do not
  abort a turn already admitted to Posoco. The stopped turn may finish normally,
  but no further recurrence is scheduled.
- **Failures**: 3 consecutive ordinary Agent failures pause a job by default.
  Busy never consumes this budget.
- **Shutdown**: ticker, actor and child workers are supervised by the same
  host-owned TaskGroup and are cancelled/settled on shutdown.
- **No persistence**: scheduled jobs and deadlines do not survive process exit.
  Host restarts require new explicit commands; this is not a durable Cron.
- **Clock**: scheduling uses the injected \`now_ms\` and \`sleep_ms\` functions;
  defaults use \`@async.now()\` and \`@async.sleep\`. The runtime has one
  bounded 250ms ticker, not one long-lived timer per job.

The scheduler does not bypass tool permissions, approvals or the existing
Agent lifecycle. It does not guarantee exactly-once external tool effects.

## Public API

\`\`\`moonbit nocheck
let loop = @loop.LoopExtension(max_failures=3)
loop.start(group~, agent~)
loop.set_session("s1")
let jobs = loop.snapshot()
loop.set_session("") // suspend all sessions
loop.shutdown()
\`\`\`

\`poll()\` is available for deterministic injected-clock tests.

## Development

From the \`posoco-extension\` workspace:

\`\`\`sh
moon check --target native
moon check --target js
moon test --target native
moon test --target js
\`\`\`

\`posoco-ext-loop\` deliberately does not implement durable task storage,
cron expressions, model-driven recurrence, session ownership election or
a synthetic \`WakeupPort\` path. Those require separate semantics and tests.
