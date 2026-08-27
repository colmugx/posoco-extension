# posoco-ext-goal

Goal-driven autonomous looping extension for [Posoco](https://mooncakes.io/docs/colmugx/posoco).

One `GoalRunner` turns an agent into a verified autonomous loop: it
publishes a byte-stable run charter as a `SystemPromptContributor`,
contributes the `goal_update_plan` tool, and accounts for turns and tokens
as an `Observer`. `GoalRunner::execute` drives `agent.run_turn` one turn
at a time — feeding a per-turn progress recitation — until the model's
completion claim survives a verifier turn, the model declares itself
blocked, the budget is exhausted, or the run stalls.

> **Targets: native + js** for the library; tests run native-only.

## Ports contributed

| Port | Contribution |
|------|--------------|
| `SystemPromptContributor` | the run charter, byte-stable for the whole run |
| `ToolProvider` | `goal_update_plan` — whole-plan rewrite, one item active |
| `Observer` | turn/token accounting, tool-call repetition tracking |

The same `GoalRunner` reference appears under every field, so the three
views share one state machine; goal-run turn inputs are driven by
`execute`, not by a pipeline hook.

## Usage

```bash
moon add colmugx/posoco-ext-goal
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-goal" @goal
```

```moonbit nocheck
// GoalRunner composes like any extension — here next to the host's model
// and session-store extensions.
let goal = @goal.goal_extension(goal_condition="fix all failing tests")
let agent = @posoco.Agent(exts=[model_ext, io_ext, goal], config=config~)
let result = goal.execute(agent, "session_1")
match result.final_status {
  Completed => println(result.final_plan.progress_line())
  Blocked(reason) => println("blocked: \{reason}")
  _ => ()
}
```

Hosts that need budgets, checklists, or custom markers build the options
directly:

```moonbit nocheck
let options = @goal.GoalOptions::default(goal_condition="fix all failing tests")
options.budget.max_turns = 20
options.completion_checklist.push("the failing tests pass")
let goal = @goal.GoalRunner(options~)
```

## The three channels

All harness output is rendered as trusted `<goal-context>` envelopes so the model can tell goal protocol from conversation. The charter forbids the model from emitting the envelope itself; its only protocol outputs are the two end-of-message tags.

- **Charter** — `SystemPromptContributor.system_prompt` returns one
  string frozen at the start of `execute` and byte-stable for the whole
  run: envelope vocabulary, the goal condition, the numbered definition
  of done, plan rules, and the tag protocol. It never changes, so it
  lives in the system prompt.
- **Progress recitation** — every work turn appends one user message, a
  `<goal-context type="progress">` envelope carrying `turn` and (when a
  token budget is set) `tokens` attributes: plan snapshot (markdown
  checklist), a `NEXT STEP:` line, and a continue instruction cycling
  through three phrasings that all end with the same
  verify-before-assuming sentence. Recitations are append-only — earlier
  ones stay in the transcript as history, the newest is current; when
  the turn budget is unlimited, `turn` carries no total.
- **Plan state** — the `goal_update_plan` tool, TodoWrite-style: pass the
  whole plan on every call, never a delta. Items are
  `{"title": String, "status": "pending"|"in_progress"|"done"}`; empty
  plans and unknown statuses come back as tool errors the model can fix,
  and `normalize` keeps exactly one item in progress (the first wins,
  extras are demoted to `pending`). A rewrite answers
  `plan updated (2/5 done)` plus structured `{summary, done, total}`;
  hosts read the live plan through `goal.plan()`.

## The completion gate

`<goal-complete/>` alone on the final line only CLAIMS completion; every
claim is routed through one verifier turn:

1. A work turn ends with the completion marker → the next turn's input is
   a `<goal-context type="verification">` prompt that re-lists the
   definition-of-done checklist and asks the model to re-check each item
   against the actual state and cite evidence.
2. The verifier ends with the completion marker → `Completed`.
3. The verifier ends with the blocked marker (failing items above it) →
   retraction: back to `Running`, with the critique prefixed to the next
   progress recitation.
4. The verifier emits neither marker → ambiguous; back to work.
5. `max_verifier_rounds` (default 2) exhausted →
   `Blocked("verification budget exhausted")`.

`<goal-blocked/>` on a work turn declares the goal blocked outright: the
reason is the last non-empty line above the tag, and the status becomes
`Blocked(reason)`.

Scanning is strict by design: a signal line's trimmed content must EXACTLY
equal a marker (prose that merely mentions a tag does not trigger it);
when several signal lines exist, the last one wins; reasons are truncated
to 200 characters. Both markers are configurable through `GoalOptions`.

Near the budget limit (`wrapup_ratio`, default 0.9; the second-to-last
turn under a turn-only budget) exactly one wrap-up turn asks the model to
update the plan with `goal_update_plan` first and then write a handoff
summary instead of rushing the marker. It only fires when a budget is set.

## Stall detection

Checked after work turns only — verifier turns never stall a run. Any one
signal parks the runner in `Paused`, and the result's `stall_reason` names
the signal (`"token output below threshold"`,
`"repeated identical tool calls"`, or `"plan unchanged"`):

| Signal | Trigger |
|--------|---------|
| token delta | `stall_turn_threshold` turns below `stall_min_tokens` tokens |
| tool repetition | `stall_repeat_threshold` identical tool calls in a row |
| frozen plan | `stall_turn_threshold` turns with an unchanged plan |

## Status and result model

| Status | Meaning |
|--------|---------|
| `Idle` | fresh, cleared, or not yet executing |
| `Running` | the execute loop is active |
| `Paused` | `pause()` was called or the run stalled |
| `Completed` | completion claim confirmed by a verifier turn |
| `Blocked(String)` | blocked marker with reason, or verifier rounds exhausted |
| `BudgetExhausted` | turn or token limit reached before completion |
| `Failed(String)` | a turn raised an error |

`execute` returns a `GoalResult`: `final_status`, `total_usage`
(`turns` / `total_tokens`), `turns_completed`, one `GoalHistoryEntry` per
turn (turn number, usage snapshot, 200-character response summary), and
`final_plan` — the structured handoff: the wrap-up prompt asks the model
to update the plan before writing the handoff, so the plan reflects what
is done and what remains. `stall_reason` is set only when a stall ended
the run. `pause` / `resume_goal` / `clear` control the runner between
runs; `resume_goal` requires calling `execute` again to continue.

## Options

| Field | Default | Meaning |
|-------|---------|---------|
| `goal_condition` | required | the goal statement, frozen into the charter |
| `budget.max_turns` | 0 | max turns; 0 = unlimited |
| `budget.max_total_tokens` | 0 | max accumulated tokens; 0 = unlimited |
| `completion_marker` | `<goal-complete/>` | claims completion (exact match) |
| `blocked_marker` | `<goal-blocked/>` | declares blocked; reason above it |
| `wrapup_ratio` | 0.9 | wrap-up turn at 90% of the budget |
| `stall_turn_threshold` | 3 | consecutive low-output or unchanged-plan turns |
| `stall_min_tokens` | 50 | token delta below this is low output |
| `completion_checklist` | `[]` | definition of done; empty = implicit item |
| `max_verifier_rounds` | 2 | verifier turns per run; exhaustion = Blocked |
| `stall_repeat_threshold` | 3 | consecutive identical tool calls |
| `plan_tool_name` | `"goal_update_plan"` | name of the contributed plan tool |

Build with `GoalOptions::default(goal_condition~)`, mutate, then
`GoalRunner(options~)` — see Usage.

## Scope

GoalRunner is **not** a model port — compose a `ModelPort` extension
alongside it. It contributes exactly one tool, one prompt contributor,
and one observer: no hooks, commands, or session stores. There are no
parallel subagents inside a goal — the loop drives one `agent.run_turn`
at a time, sequentially, against a tool-set fixed for the agent's
lifetime (composed once at `Agent` construction; a goal run never adds
or removes tools). The runner never decides the goal is met by itself:
completion is the model's marker, confirmed by the model's own verifier
turn. Failures stay in the transcript — a raising turn ends the run as
`Failed(msg)` without rewinding the session. Budget values of 0 mean
unlimited.
