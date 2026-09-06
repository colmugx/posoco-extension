# posoco-ext-plan

Plan mode extension for [Posoco](https://mooncakes.io/docs/colmugx/posoco).

While plan mode is active the agent may only run read-only tools: every other
tool call is rejected by `Hook::before_tool` and the rejection reason is fed
back to the model (on posoco's non-terminal hook rejection it returns as a
`NotExecuted(RejectedByHook)` tool result, so the model steers to read-only
investigation instead of the turn dying). Shell-like tools are gated per
invocation — `ls -la` or `git status` pass, `rm` does not. A per-turn
`<plan-context>` user message injected by `PipelineHook::before_model`
carries the current mode guidance — plan mode as a research posture: every
conclusion must be accurate and traceable — and the model submits its
finished plan through the `exit_plan_mode` tool, which echoes the plan once
in its result. Deciding the plan is an explicit user action on the product
side (cetas) with three verdicts — approve, reject (reason required), or
dismiss (cancel and stop) — carried either by a host-injected
`PlanReviewSource` or by the `plan` / `plan.approve` / `plan.reject` /
`plan.dismiss` commands.

## Ports contributed

One `PlanMode` struct implements three public Posoco ports, all sharing one
status value:

| Port | Contribution |
|------|--------------|
| `Hook` | Rejects non-allowed tools while `Planning` / `ReadyForApproval`; admits read-only shell commands; injects per-turn plan reminders via `before_model` |
| `ToolProvider` | `exit_plan_mode(plan)` + optional `enter_plan_mode()` |
| `CommandPort` | `plan` (toggle), `plan.approve`, `plan.reject <feedback>`, `plan.dismiss` |

Plan-mode discovery is through the `enter_plan_mode` tool description (only
advertised when `allow_model_entry` is true) and the per-turn `<plan-context>`
reminder injected by `before_model`; there is no static system-prompt
advertisement.

## State machine

```
Off --/plan (toggle) or enter_plan_mode--> Planning
Planning --exit_plan_mode (no review source)--> ReadyForApproval
Planning --exit_plan_mode (review: Accept)--> Off
Planning --exit_plan_mode (review: Revise)--> Planning
Planning --exit_plan_mode (review: Dismiss)--> Off (turn stops, best-effort)
Off <--/plan.approve (auto-exits)-- ReadyForApproval
Planning <--/plan.reject (feedback required)-- ReadyForApproval
Off <--/plan.dismiss-- ReadyForApproval
any --/plan (toggle)--> Off
```

- Entering never needs approval: `/plan` toggles, and the model may enter on
  its own via `enter_plan_mode` (only advertised when
  `config.allow_model_entry` is true).
- Exiting happens through a decision. Without a review source the model's
  `exit_plan_mode` call merely records the plan (`ReadyForApproval`) and
  the commands decide: `plan.approve` approves and exits, `plan.reject`
  (with required feedback) returns to planning, `plan.dismiss` discards
  and exits. With a review source the same three verdicts resolve on the
  exit call itself.
- `Dismiss` cancels the plan AND stops the turn — posoco has no tool-level
  turn kill switch, so the stop is best-effort: plan mode goes `Off` and
  the tool result instructs the model to make no further tool calls.
- Tool gating is active in both `Planning` and `ReadyForApproval`; only `Off`
  passes every tool through.
- The transition methods are package-private: hosts drive the machine
  through the tools and commands. `status()` and `stop()` stay public for
  inspection and teardown.

## Commands and shortcut

- `/plan` — toggles plan mode (bare), or `/plan on|off|status`. Declares
  `shortcut: "shift+tab"` in its `CommandDef`, so hosts that bind declared
  shortcuts (e.g. cetas-js) get a kimi-code-style Shift+Tab toggle for free.
- `/plan.approve` — approve the pending plan and exit plan mode.
- `/plan.reject <feedback>` — send the model back to planning. The reason is
  required: a reasonless reject sends the model back blind and fails.
- `/plan.dismiss` — discard the pending plan, exit plan mode, nothing
  executes.

## Plan review (the "accept plan" boundary)

`PlanMode(review=…)` wires a host-injected `PlanReviewSource`. With
one, `exit_plan_mode` resolves through the user in ONE action — the review
runs inside the exit-tool execution itself (the same seam Claude Code's
ecosystem uses): `Accept` approves and leaves plan mode together,
`Revise(feedback)` keeps planning with the feedback fed back to the model
(the type has no reasonless revise), and `Dismiss` cancels the plan and
stops the turn (best-effort — see the state machine). A review that raises
surfaces as a tool-reported error and the turn stays in planning.
`AutoAcceptReview` is the unattended (Yolo) posture: the plan auto-accepts
while every plan rule stays enforced. Without a source the flow stays
command-driven (`ReadyForApproval` + `plan.approve` / `plan.reject` /
`plan.dismiss`).

## Plan files

With a `WorkspaceFs` injected (`PlanMode(fs=…)`), planning is not in-memory
only. The assistant's planning narrative accumulates into a session draft
`.cetas/plan/<session>.md` (rewritten each planning round), and the exit
tool's required `name` argument — the LLM names its own plan — lands the
final file as `.cetas/plan/<name>_<session>.md`, removing the draft. Names
are slugified for the filesystem (hostile characters collapse to `-`);
persistence is best-effort and never fails the tool call. Hosts that mint
session ids after construction stamp them per session:

```moonbit nocheck
plan.set_session_name(session_id) // e.g. at session start
```

## Usage

```mbt nocheck
let plan = PlanMode(
  config=PlanModeConfig::{
    ..PlanModeConfig::default(),
    // Exact names or `prefix*` patterns (e.g. read-only inspection tools
    // surfaced by an MCP bridge):
    allowed_tools: ["read", "glob", "grep", "browser_*"],
    // Per-invocation shell gating: read-only commands pass with no questions
    // (ls, cat, grep, git status, find, …); anything else is steering
    // feedback — and still runs when the user approves it at a permission ask
    // (ApproveAfterConsent outranks this gate). Set to [] to reject shell
    // tools by name instead.
    shell_tools: ["bash", "shell", "sh", "zsh", "cmd", "powershell"],
    // Write tools gated by TARGET: Markdown (.md) anywhere in the
    // workspace passes ungated (research notes, draft plans — workspace
    // confinement is the write tools' own anchoring); every other change
    // belongs in the plan itself.
    write_tools: ["write", "edit", "apply_patch"],
    writable_extensions: [".md"],
    allow_model_entry: true, // let the model call enter_plan_mode itself
  },
  // Optional host-injected review — the three-verdict approval surface.
  review=Some(plan_review),
  // Optional workspace filesystem: plan-file persistence (see above).
  fs=Some(workspace_fs),
  // Optional session label for plan file names (or set per session).
  session_name="cetas-1",
  // Optional devkit EventBus: publishes the enter/exit tool names on the
  // `tool_exemptions` bus topic (payload `{"tools":[...]}`, pinned by tests)
  // — a subscribed approval gate (e.g. posoco-ext-permission) parses them so
  // those tools skip its approval asks — and publishes plan status facts on
  // the devkit status protocol — segment `"plan"`, priority 10, value
  // `"Plan"`, declaring the `accent` color role while planning or awaiting
  // approval, unregistered when off — that a status bar renders in front of
  // the model name.
  // Construct the gate FIRST — the bus is fire-and-forget, a report with
  // no subscriber is dropped.
  bus=Some(event_bus),
)
// Compose as one extension:
//   Agent(exts=[plan, ...], config=...)
```

## Notes

- Without an injected `WorkspaceFs` the extension is in-memory only; the
  plan-mode state itself (Off/Planning/ReadyForApproval) is never persisted
  across process restarts even with one.
- The approval UX (rendering the plan, prompting the user) belongs to the
  product. This package only owns the state machine, the tool gate, the
  per-turn plan reminders, the tools, and the commands.
- The gate reads tool arguments by convention: shell gating reads the
  `cmd` string field, write-target gating reads `path` or `file_path`.
  Tools whose arguments use other field names fall through to the
  conservative rejection — name them in `allowed_tools` explicitly if they
  must stay usable while planning.
- Configure `allowed_tools` with your product's read-only tool names
  (e.g. `read`, `glob`, `grep`); entries may end with `*` to match a prefix.
  The enter tool is allowed only when advertised (`allow_model_entry`); the
  exit tool is always allowed.
- Shell classification comes from the plan extension's own read-only policy
  table (`src/shell_readonly.mbt`, copied from posoco-devkit in 2026-09 and
  free to diverge from other extensions' copies) — a deliberately conservative
  steering heuristic (flags are not analyzed, quotes are not parsed, unknown
  commands classify as mutating), not a security boundary. Pair it with a
  permission gate when something must actually be enforced.
- Plan mode and permission gating are peer gates that compose through
  posoco's hook-chain rules (a user's just-given consent outranks this
  gate's rejection): plan mode bounds WHAT the agent may do before a plan
  is accepted; permission decides whether a tool runs at all. When both
  share a devkit EventBus, this extension publishes its enter/exit tools on
  the `tool_exemptions` bus topic from its own exemptions module (payload
  `{"tools":[...]}`, pinned by tests) and the subscribed approval gate
  parses them, so entering plan mode and submitting a plan never hit a
  tool-permission ask — the decision is the plan review / approval flow.
