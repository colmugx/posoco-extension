# posoco-ext-permission

A composable `Hook` permission policy for Posoco coding agents, with a
host-injected `ApprovalSource` for kimi-code-style interactive approval.

## Modes

- `ReadOnly`: approves `read`, `grep`, and `glob`; rejects mutation, shell, and
  unknown tools (no UI needed).
- `WorkspaceWrite`: approves known read tools; gates writes/shell/unknown
  through the approval source.
- `Interactive`: approves inspection; gates every side-effecting or unknown
  tool through the approval source.
- `Yolo`: pre-approves every tool; the approval source is never consulted.

## ApprovalSource — the host UI seam

The host injects an `ApprovalSource` — a callback that returns an
`ApprovalDecision`. `ask` is `async` because `Hook::before_tool` is `async`; a
host that decides synchronously implements `ask` as a plain `fn` (a sync body
satisfies an `async` trait slot under MoonBit's colorless-coroutine model):

```moonbit
pub(open) trait ApprovalSource {
  async fn ask(Self, request : ApprovalRequest) -> ApprovalDecision
}

pub(all) enum ApprovalDecision {
  AllowOnce       // approve this call, do not cache
  AllowSession    // approve and cache for this agent lifetime
  AllowAlways     // v0: equivalent to AllowSession (no persistence)
  Deny(reason~ : String)
}
```

On the js host (cetas-js), `BlockingApprovalSource` bridges this by blocking
on an async `UiPort::request` (`.wait()`) from inside the puppetry async
driver, presenting a kimi-code-style modal:

```
Tool approval
bash (shell)
> rm -rf node_modules
  Yes
  Yes for this session
  Yes, don't ask again
```

Esc → `Deny`. `AllowSession` / `AllowAlways` are remembered for the rest of
the agent's lifetime (no on-disk persistence); the cache granularity is:

- **write-class and unknown tools** — per tool name: approving `edit` once
  approves every later `edit`.
- **shell tools** — per command-segment scope: the command is split on `&`,
  `|`, `;` and newlines, a leading `rtk` is stripped (transparent project
  wrapper, so `rtk moon check` and a bare `moon check` share one scope), and
  each remaining segment scopes to its first word — except a non-transparent
  leading shim (`sudo`, `doas`, `env`, `time`, `nice`, `nohup`, `xargs`,
  `watch`), which refines to shim + next word so `sudo rm` never merges with
  a bare `rm` approval. Approving `rtk moon check` remembers the `moon`
  scope, so a later `rtk moon test` is pre-approved while `git push` still
  asks; a compound call is remembered only when *every* segment scope was
  already approved.

Skill activation (`activate_skill`, `read_skill_resource`) rides the read
class and never prompts.

## `/permission` command

The policy also implements `CommandPort`, so hosts that enumerate extension
commands (cetas-js slash autocomplete) expose `/permission` automatically:

- `/permission` (or `/permission status`) — toast with the active mode, the
  approval scopes remembered this session, and the bus-reported exempted
  tools.
- `/permission readonly|workspace_write|interactive|yolo` — switch mode at
  runtime.
- `/permission reset` — clear remembered session approvals.

## Composition

```moonbit
let approval = host_approval_source()       // host-implemented
let bus = EventBus::EventBus()              // cross-extension channel
let permissions = PermissionPolicy(
  Interactive,
  approval=Some(approval as &ApprovalSource),
  bus=Some(bus),
)
let agent = Agent::Agent(
  exts=[permissions, ..other_extensions],
  config~,
)
```

`Defer` is intentionally not used: the current Puppet runtime treats
`Hook` deferral as a terminal reject (suspend/resume is M5). The host-injected
`ApprovalSource` keeps the decision inside the policy without depending on
unimplemented suspend semantics.

## Tool exemptions (bus-reported)

`PermissionPolicy(bus=…)` subscribes the policy to the devkit
cross-extension event bus. Peer extensions report tools that carry their own
governance on the `tool_exemptions` topic (posoco-ext-plan reports its
enter/exit pair — the plan decision happens at the plan-review seam, not at a
tool-permission ask), and the reported names skip this gate entirely: no mode
check, no approval ask, plain `Approve`. Exemptions self-identify:
`/permission status` lists them as `source:name` (e.g.
`posoco_ext_plan:exit_plan_mode`) so code review can see who vouched for
what.

Composition order matters: the bus is fire-and-forget, so the subscribing
gate must be constructed before the reporting extension. Reports accumulate
and cannot be revoked. This is a trust channel, not a security boundary —
nothing at runtime verifies what an extension reports; the guarantee is code
review over the composed extensions.

## Tool classification

The policy classifies standard coding-tool names (`read`/`grep`/`glob`,
`ask_question`, and skill activation → read; `write`/`edit`/`apply_patch` →
write; `bash`/`shell`/... → shell). Follow-up work should add workspace-aware
path checks, provider namespaces, and user-defined rules.
