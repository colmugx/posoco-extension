# Capability contracts C–H (extension-side)

The Model Manager and Model Router implementations are *peers*. They implement
common interfaces; none is a compatibility layer for the other. Core
consumers must not ask which backend owns a request.

## Contracts and ownership

| Slice | Abstract extension contract | Existing implementation / boundary |
|---|---|---|
| C — Status | `ModelFactsSource`, `ModelStatusFacts`, `ModelObservation` | Managers publish read-only facts; `ext-statusbar` remains a display-only bridge. Context percentage only with a real window. |
| D — Quota/Budget | `ModelQuotaSource`, `ModelBudgetSource`; independent source/window snapshots | Do not sum independent accounts' percentages; keep caller budgets separate from subscription quota. `ext-magpie` already exposes cached quota readings. |
| E — Recovery | `ModelRecoveryAdvice`, `ModelRecoverySource` | Router handles upstream failover; `ext-ratelimit` resumes only typed final failures with epoch/supervisor checks. Never infer reset deadlines from status display values. |
| F — Usage/Catalog | `ModelExecutionFactsSource`; existing `ModelManagerControl.list_models` | `ext-stats` owns core-turn token accounting, not backend-specific estimation. Catalog uses manager-native opaque model IDs. |
| G — Compact/Subagents | Existing core `ModelPort.compact`, `InvocationScope` | Both managers bind their own execution ports; no second compaction router or subagent identity guessing. |
| H — Handoff | Existing `HandoffWorkSource`, `HandoffWorkspaceProbe` | Project/host injects real work facts, not private manager state. |

## Data constraints

- `Known`, `Stale`, `Unknown`, `Unavailable`, and `Unsupported` have
  different meanings. Neither unknown nor unsupported means 0%.
- Source references are opaque. No email, secret token or session transcript
  belongs in quota facts.
- A served source and model refer to the **last completed execution**, not a
  commitment about the next route.
- The presence of a quota number alone is **not** grounds to schedule a
  retry or resume. Only a typed final failure with explicit recovery policy
  may do so.
- The status display should omit unknown quota percentages in its compact
  state rather than display constant warning noise.
- All optional fact sources can be injected by composition; callers do not
  downcast to a concrete manager.

## Integration boundary

Concrete adapters for each manager should implement only the traits for
facts they can produce, returning `Unknown` when authoritative data is
absent and `Unsupported` when the capability cannot be represented.
The future host composition injects these optional trait objects and leaves
Statusbar, Session, Stats, Recovery and Handoff independent of backends.

The contract does **not** assert a Gateway model-scoped quota endpoint
already exists. Until authoritative per-model source attribution becomes
available, presenting a session-specific upstream quota as confirmed would
be inaccurate.
