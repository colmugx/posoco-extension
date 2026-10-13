# posoco-kit-model-management

The provider-neutral **Model Manager control contract** for Posoco: the small
shared vocabulary that lets a host drive any Model Manager — today the local
slot router in `posoco-ext-llm`, tomorrow independent managers such as the
planned `posoco-ext-magpie` — through one plain trait reference, without
knowing the concrete manager type.

## Architectural boundary

- **This kit** owns the shared control vocabulary only: manager identity, an
  ordered model catalog snapshot, the active-selection report, selection and
  effort switching, and their typed errors. It has zero dependencies — no
  `colmugx/posoco`, no `ModelPort`, no `ModelSlot`, no provider extension, no
  transport.
- **`posoco-ext-llm`** owns local model-management behavior (slot routing,
  provider catalogs, credentials, `/model`-`/effort`-`/login`-`/status`
  commands) and implements the contract by projecting its existing public
  API.
- **A future `posoco-ext-magpie`** will independently implement the same
  contract without depending on the local manager or on any provider
  extension.
- **Posoco core** remains responsible for the Agent lifecycle and the
  one-`ModelPort` composition invariant; manager control is a separate,
  control-plane concern and never bypasses composition.

## Public API

```mbt nocheck
// ── control.mbt ─────────────────────────────────────────────────────────
pub(open) trait ModelManagerControl {
  fn manager_id(Self) -> String
  fn list_models(Self) -> Array[ManagerModelInfo]
  fn active_selection(Self) -> ManagerSelection
  fn select_model(Self, model_id : String) -> Unit raise ModelManagerError
  fn select_effort(Self, effort : String) -> Unit raise ModelManagerError
}

pub(all) struct ManagerModelInfo {
  model_id : String          // opaque selection key; no slash shape assumed
  label : String
  provider_id : String
  context_window : Int32?    // None = unknown, never fabricated
  capabilities : Array[String]
  efforts : Array[String]    // advertised, ordered least to most
  default_effort : String?
  display_group : String?
} derive(Eq, Debug)

pub(all) struct ManagerSelection {
  model_id : String
  effort : String?           // None = no explicit effort selection
  pending : Bool             // persisted id absent from the current catalog
} derive(Eq, Debug)

pub(all) suberror ModelManagerError {
  UnknownModel(String)         // id absent from the catalog (incl. pending)
  UnsupportedEffort(String)    // effort not advertised by the model
  EffortNotApplicable(String)  // efforts advertised, no way to apply one
} derive(Debug)
```

## Semantics

- **Opaque ids.** `model_id` is whatever key the manager selected by. Nothing
  in the contract may assume a `provider/model` string.
- **Honest absence.** Unknown facts stay `None`; a persisted selection whose
  model is missing from the catalog reports `pending = true` and is never
  silently rewritten to a fabricated default. Requests against a pending
  selection fail visibly until the model appears (login, refresh).
- **Snapshot isolation.** `list_models` returns copies; later catalog changes
  never mutate a returned snapshot.
- **Failure isolation.** A rejected `select_model`/`select_effort` mutates
  nothing: previous selection, effort, and catalog stay intact.
- **Effort rules.** Switching the active model resets any applied effort;
  selecting an effort is validated against the active model's own advertised
  levels. Managers apply efforts through their provider-owned mechanism —
  the contract never duplicates it.

## Usage

```moonbit
// The manager may be the local router or any peer manager; the host only
// ever sees the trait.
let control : &ModelManagerControl = router as &ModelManagerControl
control.select_model("openai/gpt-5.1")
control.select_effort("high")
let selection = control.active_selection()
if selection.pending {
  // surface "waiting for <model_id> to appear" instead of guessing
}
```

## Router projection (`posoco-ext-llm`)

| `ModelManagerControl` | `RouterModelPort` | Notes |
|---|---|---|
| `manager_id` | — | constant `"posoco_ext_llm"` |
| `list_models` | `list_slots` | slot projected verbatim; slot id is the opaque `model_id`; `context_window` is the provider-declared value (`None` stays unknown — the status bar's display fallback is not catalog truth) |
| `active_selection` | `active_slot_id` + `active_effort` | `pending` = the persisted default whose slot is absent (`allow_missing_default`) |
| `select_model` | `switch_slot` | inherits its validation, effort reset, model/ctx status publication, provider event, and quota invalidation |
| `select_effort` | `select_effort` | inherits its validation and the provider-owned rebuild hook; the adapter only relabels failures |

Error relabeling: unknown slot → `UnknownModel`; unadvertised effort →
`UnsupportedEffort`; advertised efforts without a rebuild hook →
`EffortNotApplicable`.
