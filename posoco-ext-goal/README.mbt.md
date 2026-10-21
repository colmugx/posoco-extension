# posoco-ext-goal

A **goal control loop** for Posoco. The model proposes work and claims
completion; the extension controls budgets, state, continuation and the
acceptance gate. No DecisionPort or JEV login is required.

The Goal extension contributes a sequential `goal_update_plan` tool, a
session/run-scoped Observer, and a Lifecycle port for **optional**
semantic advice. The charter rides the first working-turn user input
and is not reinserted on resume.

## Install

```sh
moon add colmugx/posoco-ext-goal
```

Compose a goal together with a ModelPort and a SessionStore:

```moonbit nocheck
let goal = @goal.goal_extension(goal_condition="make the failing tests pass")
let agent = @posoco.Agent(exts=[model_ext, io_ext, goal], config=config~)
let result = goal.execute(agent, "session_1")
```

This **does not automatically authorize external actions** or change host
tool permissions. The caller is responsible for selecting and supervising
the appropriate model, tools, scope and permissions.

## M1: bounded execution, scope, resume and checkpoint

- The default turn budget is **20 turns**. Set `budget.max_turns = 0`
  explicitly to opt into an unlimited turn count. Token budgets default
  to unlimited (`max_total_tokens = 0`); reported token usage is evaluated
  between turns and is **not** a hard provider-side token cap.
- Each model request/response is counted only for the active run/session.
  Session redirects are carried into subsequent work. A repeated call to
  `execute` on a paused goal **preserves** the plan, turns, usage, charter
  and history; it rejects an unrelated session.
- State-mutating plan updates are `Sequential` rather than `Parallel`.
  Stall heuristics use known model *output* tokens (not prompt tokens) and
  do not treat missing usage or tool activity as proof of inactivity.
- `goal.pause()` stops at the next safe turn boundary.
  `goal.resume_goal()` followed by `goal.execute(agent, session_id)`
  resumes an in-memory run. `clear()` resets a stopped run.
- `goal.checkpoint()` returns a versioned JSON document from a stopped
  nonterminal run, for storage **alongside the matching agent session
  transcript**. A new Idle runner with the same Goal contract can call
  `restore_checkpoint(snapshot)`, then `resume_goal()` and `execute`.
  Version, acceptance criteria, markers, session, turn count and budget are
  validated before state mutation.

Checkpoint export/import does not itself persist files. The host must
durably store both the checkpoint and its session messages. A crash in
the middle of an external tool effect may still require reconciliation:
**exactly-once tool execution is not guaranteed**.

## M2: evidence-backed completion

A final assistant-message line containing `<goal-complete/>` is a
**completion claim**, not a verdict. On the **first** claim the runner
calls the host-provided `GoalVerifier` directly. There is no extra
self-confirmation turn where the same model repeats the tag.

`GoalVerifier::verify(GoalVerificationRequest)` returns:

| Assessment | Effect |
|---|---|
| `Verified(Array[GoalEvidence])` | `Completed`, only if every criterion has evidence with a nonempty `source` and `reference` |
| `Rejected(reason)` | Retract the claim, prepend the reason to the next working prompt and continue within budget |
| `Inconclusive(reason)` | `Paused` for review; never report `Completed` |

Without a verifier, claims are `Inconclusive`, so **goal completion
fails closed**. An empty `completion_checklist` uses the implicit
criterion name `"goal"`. An explicit checklist must be fully covered,
exactly matching the criterion strings. The verifier is trusted code
supplied by the **host**; it must check real evidence (e.g. test
execution results, artifacts or human approval). A model message is not
independent evidence.

```moonbit nocheck
// Host implements GoalVerifier::verify and validates its own external facts.
goal.set_verifier(my_verifier)
```

The blocked marker `<goal-blocked/>`, also only on the last
nonempty line of an assistant message, yields `Blocked(reason)` with
the preceding text as reason. `max_verifier_rounds` now bounds
independent verifier invocations, **not model verifier turns**.
Exhaustion produces `Paused` / `Inconclusive`, not a fake success.

`GoalResult` exposes `assessment` and `semantic_probability` alongside
status, history, usage and final plan. A `Completed` status requires a
validated `Verified` assessment.

## M3: optional DecisionPort semantic adviser

Semantic judgement is **opt-in**. Set
`options.enable_semantic_advice = true` *before composing the Agent*.
When a DecisionPort is installed, the Lifecycle port discovers it through
`CompositionView::decision`. Opting in declares `Capability::Decision`
in the manifest so the curated view exposes an installed provider; the
capability remains **optional** and Cetas JS hosts without a provider
still compose and run normally.

```moonbit nocheck
let options = @goal.GoalOptions::default(goal_condition="deliver feature")
options.enable_semantic_advice = true
let goal = @goal.GoalRunner(options~)
```


When deterministic stall detection would pause an otherwise running goal,
the adviser can also answer a typed `goal_continue_has_value` question.
A probability at least `semantic_stall_threshold` (default 0.75)
defers the stall for one more *ordinary, budgeted* work turn. The default
`max_semantic_stall_deferrals = 1` is an absolute per-run cap on this
behavior and is persisted in checkpoint format **v2**. Budget exhaustion
always wins; absent, malformed or failed decision responses use the
deterministic Pause path. These thresholds are conservative policy
defaults, **not calibrated guarantees** of semantic correctness.

On a completion claim, a typed `DecisionQuestion::Boolean` estimates
semantic satisfaction. Its validated probability is attached as
advisory telemetry; malformed responses and provider failures produce
`None` without failing the goal. **DecisionPort never overrides
verified evidence, supplies proof, changes permissions, or grants
completion**. Opt-in can disclose the goal, claim and checklist to the
configured DecisionPort provider; hosts should choose an appropriate
privacy policy.

For manual wiring, `goal.set_decision_adviser(decision_port)` is also
available. The verifier remains separately configured.

## Status and security contract

`Idle`, `Running`, `Paused`, `Completed`, `Blocked(String)`,
`BudgetExhausted` and `Failed(String)` describe **execution**.
`Verified`, `Rejected` and `Inconclusive` describe **assessment**.
They are intentionally independent. A plan item marked `Done` is not
verification evidence.

The extension is not a ModelPort or a permission provider and does not
itself execute tests, browse files or attest the workspace revision.
Those capabilities belong to host-provided tools and verifiers. Posoco
composition determines capabilities; JEV is only one possible provider
of advisory DecisionPort evaluations.
