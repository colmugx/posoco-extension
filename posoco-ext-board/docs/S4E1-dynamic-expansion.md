# S4E1 — controlled dynamic workflow expansion

S4E1 is an optional, trusted-headless proposal/approval/commit API for native and
JS. It is **not** an autonomous planner loop or an execution-scope extension.

## Four separate steps

1. **Agent-generated proposal:** untrusted structured content, not Board commands.
2. **Host-approved mutation:** the host approves an exact validated preview and its
   authority, budgets and Board revision. Approval alone writes nothing.
3. **Authoritative committed graph:** the single BoardCoordinator persists one
   detached successor before committing and publishing the complete expansion.
4. **Authorized execution:** a separate future host decision; generated tasks do
   not enter an existing S4C/S4D scope. S4E1 never dispatches them.

```text
explicit host planning authorization
  -> DynamicPlanSource (optionally OwnedAgentPlanSource through the S4A owner)
  -> bounded strict decoder -> pure domain DAG preview
  -> explicit host approval -> host canonical ID allocation
  -> BoardBackend.expand_graph -> BoardCoordinator
  -> propose -> persist one successor -> commit -> publish GraphExpanded
  -> fresh snapshot -> existing S4B planner outlook
```

`expansion` depends on the headless backend and existing planner. The optional
`expansion/agent` adapter depends on S4A execution. The domain/store/coordinator
never depend on Agent execution or the proposal parser. There is no new Agent
runtime, scheduler, execution journal or durable proposal-control FSM.

## Proposal JSON schema (version 1)

All fields shown below are required. No other keys are accepted at any level.
Unlike the illustrative ticket schema, dependencies are attached to each proposed
task; `key` is its proposal-local reference, never a canonical Board ID.

```json
{
  "schema_version": 1,
  "proposal_id": "proposal-001",
  "parent_task_id": "parent",
  "base_revision": 42,
  "tasks": [
    {
      "key": "research",
      "title": "Research implementation options",
      "description": "Compare the authorized approaches.",
      "priority": "high",
      "definition_of_done": ["Options documented"],
      "depends_on": [{"existing": "approved-input"}]
    },
    {
      "key": "implement",
      "title": "Implement selected approach",
      "description": "Build the chosen implementation.",
      "priority": "normal",
      "definition_of_done": ["Implementation validated"],
      "depends_on": [{"local": "research"}]
    }
  ]
}
```

- `schema_version` is the exact numeric literal `1`.
- `base_revision` is a canonical nonnegative JSON integer within the wire-safe
  integer range, not a string, fraction, exponent, negative zero or rounded number.
- Priorities are exactly `low`, `normal`, `high`, `critical`.
- Each dependency contains **exactly one** `local` or `existing` string.
  Forward local references are supported; local and existing namespaces are
  disjoint. Existing IDs must be explicitly permitted by the host.
- IDs/keys are nonempty, bounded and contain no whitespace/control characters.
  Titles and DoD items must contain meaningful, unpadded text. Description is a
  required text field; empty is allowed, whitespace-only nonempty text is rejected.
  It is never a control-plane instruction.
- Task/DoD/dependency arrays are explicit, even when empty. The task array itself
  must be nonempty. Duplicate task keys, duplicate edges and unresolved references
  reject the entire proposal.

The decoder scans before using a generic JSON object map, so duplicate keys
(including escaped equivalent names) cannot disappear during parsing. It rejects
unknown/missing fields, invalid numbers, raw/escaped lone surrogates, unescaped
control characters, trailing input, oversized strings/containers and excessive
JSON nesting. Text is preserved, not silently truncated or Unicode-normalized.
No generated text is evaluated as code. There are no shell/path/credential/URL/
tool-invocation control fields; such unknown structural fields are rejected.
Approved task text remains untrusted data, never permission to execute it.

## Explicit policy and graph invariants

`ExpansionPolicy` centralizes the initial ceilings; hosts may tighten them:

| Bound | Default / ceiling |
| --- | ---: |
| Tasks per proposal | 20 |
| Dependency edges per proposal | 60 |
| Dependencies per task | 12 |
| Identifier/key length | 128 UTF-16 units |
| Title length | 256 UTF-16 units |
| Description length | 4096 UTF-16 units |
| DoD items per task | 16 |
| DoD item length | 256 UTF-16 units |
| JSON payload size | 65536 UTF-8 bytes |
| JSON nesting / dependency depth | 16 |
| Committed expansions per workflow | 16 |
| Cumulative generated tasks per workflow | 200 |

Oversized proposals are rejected as a whole, before graph operations. Workflow
usage comes from durable expansion history, not a resettable local counter.

The pure validation path restores a detached authoritative snapshot and calls
`BoardDomain::preview_expand_graph`, using the **same** domain dependency validator
as normal Board commands. It checks parent existence, permitted/existing external
dependencies, unique local resolution, self-dependencies, duplicate edges and
cycles in the combined graph. Existing nodes/edges are never rewritten. Therefore
a new-to-old-to-new cycle cannot be introduced by this additive API: old nodes
cannot point at newly allocated IDs, and dangling references are invalid in the
baseline. Malformed baselines fail closed rather than being repaired by a proposal.
Validation never changes the supplied snapshot. After domain validation, a bounded
level walk enforces the longest dependency path reachable from any generated task,
including existing dependencies (depth counts nodes, so 16 nodes are allowed).
This is a resource-budget check, not a second cycle engine; unrelated pre-existing
paths do not consume an expansion's depth budget.

## Authorization, preview and approval

Construct one `ExpansionHost` for one proposal and explicitly provide an
`ExpansionAuthorization`. Absence defaults to denied. Authorization freezes:

- host authorization ID, workflow ID and parent Task ID;
- workflow Task scope (which must contain the parent);
- separately permitted existing dependency IDs;
- deadline and maximum new tasks/edges.

It is an in-process, single-use capability. Claiming it consumes it even when
source generation, decoding or validation fails or is cancelled. Reusing the
same object in another host cannot replenish it. The trusted host owns the
meaning and authenticity of its workflow scope; no browser token mints authority.

The explicit API sequence is `prepare(payload, authorization)` **or**
`generate(source, authorization)`, then `preview()`, `approve(preview, approver)`,
then `commit(approval)`. No step implicitly invokes the next. The host approver
must return `Grant`; denial writes nothing. Preview getters return detached data.
Approval is opaque and bound to the exact in-process preview, normalized proposal
SHA256 digest, workflow/parent, expected revision, deadline, scopes and budgets.
A lookalike preview/approval from another host is not accepted.

The small ephemeral lifecycle is Empty -> Validated -> AwaitingApproval ->
Approved -> CommitRequested -> Committed, with Rejected, Conflict and Uncertain
outcomes. Generated/decoded intermediates do not need durable records. Awaiting
approval is not executable work. Hosts cannot replay an approval after commit.
Any intervening Board revision makes it stale, including an unrelated edit or
an active Agent's Attempt settlement. Refresh/revalidate and obtain a new explicit
host approval; never silently rebase an approved graph onto a different revision.

## Canonical identities and atomic commit

Only after approval and fresh validation does the trusted allocator produce the
complete `key -> BoardTaskId` mapping. The default allocator produces bounded
host-derived IDs; custom allocators are trusted and must not return collisions,
blank/invalid IDs or authoritative identities chosen by the model. Those outputs
are checked before any submission. Allocation occurs once, not during preview
or reconciliation. No Attempt, session, execution or command ID comes from JSON.

The privileged typed backend operation is additive `ExpandGraph`, **not** a loop
of `board.task.create` calls. Domain proposal construction:

1. Detaches all candidate tasks and verifies expansion identity/parent.
2. Builds all new nodes in a detached successor so forward references resolve.
3. Validates every dependency using the ordinary domain DAG rules.
4. Adds one `ExpansionRecord` alongside the graph.
5. Advances Board revision **exactly once**, emitting one `GraphExpanded` event.

Every generated Task starts at Created, with no Attempts. Existing Tasks,
Attempts, stage/review decisions and execution identities are untouched.
Coordinator optimistic revision checking precedes persistence. The coordinator
is the only writer: one coherent successor and its event go through the existing
persist -> commit -> publish pipeline. No candidate node is published early.

`ExpansionRecord` contains proposal ID, workflow/parent lineage, ordered complete
local-reference mapping, creation time and `sha256:` content digest. The domain
digest length-frames UTF-8 fields and includes canonical IDs and all candidate
content/dependencies. The approval digest separately binds proposal revision and
local/existing reference tags. Array order is significant. No raw prompt or
unapproved response envelope is added to the identity history. Approved task
content necessarily becomes normal Board data and authoritative event content.
The `moonbitlang/x` dependency supplies SHA256; there is no handwritten hash.

## Durability, uncertainty and reconciliation

The native store retains the existing durability boundary: fsynced temporary
snapshot, audit append/fsync, snapshot rename and directory fsync. Snapshot rename
is the visibility boundary. The audit journal is **not** replay authority: an
ahead event after a failed pre-rename write cannot create part of a graph.
Snapshot and audit are not claimed to be a distributed transaction.

Host diagnostics distinguish `DecodeFailed`, `InvalidProposal`,
`PolicyBudgetExceeded`, `InvalidAuthorization`/`DefaultDenied`/`Expired`,
`StalePreview`, `DuplicateProposal`, `ApprovalMismatch` and `DigestConflict`.
`DomainRejected` retains typed DAG/revision errors, while `Backend` retains
`PersistFailed`, `DurabilityUncertain`, restore and availability errors.

The identity and all graph nodes live in the **same snapshot replacement**, not
in a second expansion journal. Committed proposal IDs cannot commit again, even
with fresh canonical IDs. Reusing an ID with different content fails closed.
Typed domain/coordinator errors distinguish rejected graph/revision/identity,
store failures and uncertain durability; the proposal host wraps these without
turning failures into success.

On cancellation or an ambiguous commit result, the host enters Uncertain and
freezes its canonical mapping and expected domain digest. It cannot submit again.
`reconcile()` only reads settled authoritative history: a matching record proves
the complete expansion committed; a contradictory digest is a conflict; absence
is **not** permission to replay or regenerate IDs. Coordinator reconciliation may
confirm a visible candidate and publish it, while still returning uncertainty to
the initiating caller. It never resubmits the mutation.

After restart, `recover_expansion(backend, proposal_id)` is a read-only identity
lookup. Preserve the original mapping/content for comparison. Missing/corrupt/
ambiguous v2 identity records fail restore. This slice supplies no automatic crash
replay or authority recovery and makes no exactly-once claim for Agent effects.

## Authoritative events and client replay

One `board.graph.expanded` event carries the complete new task array, proposal
identity, parent/workflow, ordered mapping and digest. It has one server-assigned
transport sequence and the single new Board revision. The backend publishes only
after the durable commit hook. Command acceptance is not a replica mutation.

The client requires the exact next sequence and next Board revision, validates
all entities and mappings plus the complete graph, and only then installs the
whole update. Duplicates are ignored by sequence; gaps, malformed graphs or
conflicting IDs invalidate the baseline and require a snapshot. Clients do not
invent sequence numbers. `protocol-fixtures/v1/graph-expanded.json` is canonical
read/event contract material. The eight browser command names remain unchanged;
there is no WebSocket dynamic-expansion mutation route.

## Agent path and ownership

`DynamicPlanSource.generate(DynamicPlanContext)` is the host seam. Context contains
only approved lineage, dependency IDs and bounds, not arbitrary Board metadata.
The host supplies its bounded requirements and any separately authorized task
context; Board does not synthesize a prompt from private metadata.

`OwnedAgentPlanSource` implements this seam using the **existing S4A owner**, a
host-supplied dedicated queued Execute Attempt/request, an exact context match,
explicit planning authorization callback and a bounded deadline/timeout. It does
not construct a second owner or Agent. Do not compose competing S4C/S4D/direct
admission authorities against a runner-dedicated owner; follow S4D composition
rules and allocate planning work only through an explicitly permitted host path.

The opt-in `BoardExecutionResultChannel` captures pure bounded assistant text from
the direct `Agent::run_turn` result only after `run_scoped` joins. S4A's existing
scoped observer/model gate establishes actual session/run/turn identity; global
Observer output ordering never attributes a result. Reading requires the exact
Task/Attempt/execution/session/run/turn binding to be Settled + Completed, and
consumes the output once. Failed/cancelled/unresolved turns cannot yield a plan.
The channel is ephemeral, disabled by default, and never serialized in the
execution journal. Use one private channel per planning adapter/slot/request.

The host's extension factory is trusted, not sandboxed: supply isolated planning
extensions, **no Board mutation tools**, no implicit credentials/tool permissions,
and no durable prompt/output logger or session store unless separately approved.
The default Board integration persists neither prompts nor raw model responses.
Planning admission/settlement still performs S4A Attempt bookkeeping and changes
Board revision. Proposal `base_revision` must match the authoritative revision
**after** that settlement; concurrent edits invalidate it. This slice does not
silently rewrite the model's revision or predict/retry through conflicts.

## Concurrent execution and post-commit planning

Expansion neither cancels active Agents nor touches their identity/edges. Existing
slot bounds, unique Attempt admission and the single execution journal remain
owned by S4A/S4D. A graph commit does not retroactively revoke a model gate that
already admitted work. Subsequent S4B admissions read fresh authoritative state.

After commit, call `outlook()` explicitly. It reads a fresh snapshot and invokes
the existing pure S4B planner, reporting generated Task IDs, Created/Attempt state,
structured blockers and whether each ID lies outside the frozen workflow scope.
Default execution policy is disabled. Created tasks with no queued Execute
Attempt are blocked; dependency completion is the Board stage Done, not an
Agent's successful outcome. This is reporting, not execution authorization.
No task is moved to Ready, no Attempt queued, no dependency marked Done and no
Review decision recorded. S4E2 will handle separately approved execution scope.

## Compatibility, disablement and rollback

S3 snapshot schema v1 remains readable with empty expansion history. New writes
use schema v2 with required complete history. Existing execution journal v1,
manual Board commands and S4A–S4D APIs retain their semantics. Source consumers
constructing `BoardStateSnapshot` records must add `expansions: []` when upgrading.
Older clients do not understand the new event; deploy the updated replica or
recover through an authoritative snapshot rather than treating unknown events
as single-task creates.

To disable expansion, omit the optional host/source composition and stop granting
authority; the browser remains manual. Preserve snapshots and identity history.
Before deploying, back up Board data under the host's normal maintenance policy.
Older binaries cannot read v2 snapshots/new audit events: rollback after a commit
requires a reviewed offline migration or restoring a consistent pre-upgrade
backup with all writers stopped. Do not delete identity records, downgrade the
schema field, or remove generated tasks merely to allow a retry. Reverting code
cannot undo already authorized Agent effects.

Known limits: no autonomous recursion, auto-approval, auto-dispatch, graph rewrites,
cross-host leases, crash replay, browser execution authorization or Cetas/product
integration. Authorization/approval are in-process host capabilities, not signed
remote messages. JS durable storage remains host-injected; the memory store is
ephemeral/test-only. Deterministic actual-Agent tests are not live-provider or
cross-process crash-kill evidence.
