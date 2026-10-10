# S4A readiness: execution integration seams

This is a technical inventory, not an execution design. S3C6 adds no execution
owner, scheduler, persistence format or protocol field. Board paths below are
relative to `posoco-ext-board/`; core references were checked against the pinned
`colmugx/posoco@0.22.0` source and interfaces under `.mooncakes/colmugx/posoco/`.

## Already available

| Capability | Actual seam |
| --- | --- |
| Durable tasks, attempts and one-shot review decisions | `src/domain/records.mbt`, `src/domain/propose.mbt`; domain validation is authoritative. Review decisions do not finish attempts or move tasks. |
| Persist-before-commit, uncertainty reconciliation | `src/coordinator/actor.mbt`, `src/store/store.mbt`; failed pre-visibility writes publish nothing, uncertain writes reload before settlement. |
| Headless service | `BoardBackend` in `src/backend/backend.mbt`; `BoardExtension::backend()` in `src/extension.mbt`. No browser or network lifecycle is required. |
| Typed command handling | `src/client/commands.mbt`, `src/protocol/command_decoder.mbt`, `BoardBackend::handle_command` in `src/backend/commands.mbt`. IDs correlate results, not durable deduplication. |
| Authoritative events, snapshots, replay | Commit hook in `src/backend/bootstrap.mbt`, projection in `src/protocol/projection.mbt`, subscriptions in `src/backend/event_hub.mbt`. `seq` is not Board revision. |
| Observer telemetry | `board_projection` in `src/projection.mbt`; `EventScope` becomes `BoardEventScope`. Telemetry is bounded and process-local, not an execution journal. |
| Standalone composition | `BoardRuntime::attach/close_server/shutdown` in `src/runtime/runtime.mbt`; optional MoonBack adapter in `posoco-ext-board-native/src/server.mbt`. Closing presentation leaves the backend attached. |
| Restart normalization | `recover_snapshot/load_recover_persist` in `src/store/store.mbt`: running tasks become Suspended and running attempts become Interrupted before readiness. This is Board recovery, not proof of execution termination. |

## Not yet available

- Real Agent execution or execution ownership: Board owns no `Agent`,
  `AgentControl` or execution worker; Queue/Start/Finish are manual bookkeeping.
- A durable binding between an Attempt and an Agent session/run/turn.
  `Attempt` has no execution correlation fields; domain wire events have
  `scope=None`. Scoped telemetry has no Attempt ID.
- Cancellation propagation. A `cancelled` Board outcome does not cancel a run.
- Execution completion/failure/cancellation mapped into durable Attempt
  settlement. A terminal manual record does not verify an actual execution.
- Crash/restart reconciliation across Board persistence and Posoco execution.
  Retained telemetry cannot establish whether a run survived or completed.
- Execution admission, one-active-run attribution enforcement, scheduling or
  a dynamic workflow runner.

## Existing Posoco seams and S4A questions

1. **Starting work.** Core `Agent::run_turn` consumes a Message and session ID;
   `Agent::run_scoped` owns a structured Agent lifetime (`src/agent.mbt`,
   exported `src/pkg.generated.mbti`). Which host owns
   that Agent, and how will explicit user intent become its input? A Board
   Start command must not be treated as execution without that contract.
2. **Owning execution tasks.** `CompositionView::tasks()` exposes Agent-owned
   `Tasks` only to extensions declaring `Capability::Tasks`
   (`src/port/composition_view.mbt`, `src/port/task.mbt`). `TaskSpec` includes
   `session_id`, a `run` closure, mode and optional timeout; `TaskHandle`
   provides `wait/cancel`. Board currently declares no such requirement
   (`posoco-ext-board/src/extension.mbt`). Is ownership host-side or through
   this existing capability? Neither path is implemented here.
3. **Correlation and attribution.** Core Observer `on_event_at` receives optional
   `EventScope{session_id, run_id, turn_id}` (`src/port/observer.mbt`,
   `src/types/session.mbt`). Where will Attempt ID ↔ execution identity live,
   and who enforces one active attributed run? Do not infer this join from
   task stage, Attempt Running, event order or unscoped diagnostics.
4. **Completion and cancellation.** `TaskHandle::wait()` returns a `TaskOutcome`
   containing receipt and `TaskStatus::{Completed, Failed, TimedOut, Cancelled}`
   (`src/port/task.mbt`). Direct Agent turns return `TurnResult`, a different
   contract. Host control `Agent::control()` exposes identity-guarded
   `AgentControl::abort_active` (`src/agent_control.mbt`, `src/runtime/control.mbt`).
   Which owner translates the selected execution contract into exactly one
   explicit durable settlement, including conflicts and uncertain writes?
5. **Shutdown and recovery.** `Agent::run_scoped/shutdown` owns core cleanup;
   Board runtime shutdown owns presentation and coordinator shutdown. What
   cancels/joins execution before its owner exits, and what durable correlation
   allows a fresh process to reconcile Interrupted attempts? Board restart
   normalization alone cannot answer this. Lost command results still require
   authoritative reconciliation, never automatic mutation replay.

## Verification boundary

S3C6 deterministic web tests and native service/security tests validate manual
operations and reconciliation, not Agent integration. The PR records actual
browser smoke evidence or its environment limitation separately. S4A must supply
execution ownership/correlation/cancellation/recovery evidence before describing
any Board status as live Agent execution.
