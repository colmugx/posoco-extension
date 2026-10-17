///|
/// S4E1 expansion policy bounds. Every numeric budget lives here; nothing in
/// this package reads an implicit constant. Defaults are deliberately tight
/// (20 new tasks, 60 new edges, 256-unit titles); a host may tighten any
/// bound but never exceed the absolute ceiling next to it, and the decoder
/// independently refuses larger inputs so a hostile policy cannot disable
/// structural safety.
pub struct ExpansionPolicy {
  priv max_tasks_ : Int32
  priv max_edges_ : Int32
  priv max_deps_per_task_ : Int32
  priv max_key_chars_ : Int32
  priv max_title_chars_ : Int32
  priv max_description_chars_ : Int32
  priv max_dod_items_ : Int32
  priv max_dod_item_chars_ : Int32
  priv max_payload_bytes_ : Int32
  priv max_depth_ : Int32
  priv max_workflow_expansions_ : Int32
  priv max_workflow_tasks_ : Int32
}

///|
/// Clamp one bound between its floor and its absolute ceiling. A host can
/// tighten a bound but a hostile or broken policy value can never widen it
/// past the ceiling documented here.
fn clamp_bound(value : Int32, ceiling~ : Int32, floor~ : Int32) -> Int32 {
  value.clamp(min=floor, max=ceiling)
}

///|
/// Policy defaults. `max_tasks`/`max_edges`/`max_title_chars` and the
/// workflow cumulative bounds are the S4E1 contract numbers; the remaining
/// bounds are conservative defaults documented in
/// `docs/S4E1-dynamic-expansion.md`.
pub fn ExpansionPolicy::ExpansionPolicy(
  max_tasks~ : Int32 = 20,
  max_edges~ : Int32 = 60,
  max_deps_per_task~ : Int32 = 12,
  max_key_chars~ : Int32 = 128,
  max_title_chars~ : Int32 = 256,
  max_description_chars~ : Int32 = 4096,
  max_dod_items~ : Int32 = 16,
  max_dod_item_chars~ : Int32 = 256,
  max_payload_bytes~ : Int32 = 65536,
  max_depth~ : Int32 = 16,
  max_workflow_expansions~ : Int32 = 16,
  max_workflow_tasks~ : Int32 = 200,
) -> ExpansionPolicy {
  {
    max_tasks_: clamp_bound(max_tasks, ceiling=20, floor=1),
    max_edges_: clamp_bound(max_edges, ceiling=60, floor=0),
    max_deps_per_task_: clamp_bound(max_deps_per_task, ceiling=12, floor=0),
    max_key_chars_: clamp_bound(max_key_chars, ceiling=128, floor=1),
    max_title_chars_: clamp_bound(max_title_chars, ceiling=256, floor=1),
    max_description_chars_: clamp_bound(
      max_description_chars,
      ceiling=4096,
      floor=0,
    ),
    max_dod_items_: clamp_bound(max_dod_items, ceiling=16, floor=0),
    max_dod_item_chars_: clamp_bound(max_dod_item_chars, ceiling=256, floor=1),
    max_payload_bytes_: clamp_bound(max_payload_bytes, ceiling=65536, floor=64),
    max_depth_: clamp_bound(max_depth, ceiling=16, floor=2),
    max_workflow_expansions_: clamp_bound(
      max_workflow_expansions,
      ceiling=16,
      floor=1,
    ),
    max_workflow_tasks_: clamp_bound(max_workflow_tasks, ceiling=200, floor=1),
  }
}

///|
pub fn ExpansionPolicy::max_tasks(self : ExpansionPolicy) -> Int32 {
  self.max_tasks_
}

///|
pub fn ExpansionPolicy::max_edges(self : ExpansionPolicy) -> Int32 {
  self.max_edges_
}

///|
pub fn ExpansionPolicy::max_deps_per_task(self : ExpansionPolicy) -> Int32 {
  self.max_deps_per_task_
}

///|
pub fn ExpansionPolicy::max_key_chars(self : ExpansionPolicy) -> Int32 {
  self.max_key_chars_
}

///|
pub fn ExpansionPolicy::max_title_chars(self : ExpansionPolicy) -> Int32 {
  self.max_title_chars_
}

///|
pub fn ExpansionPolicy::max_description_chars(self : ExpansionPolicy) -> Int32 {
  self.max_description_chars_
}

///|
pub fn ExpansionPolicy::max_dod_items(self : ExpansionPolicy) -> Int32 {
  self.max_dod_items_
}

///|
pub fn ExpansionPolicy::max_dod_item_chars(self : ExpansionPolicy) -> Int32 {
  self.max_dod_item_chars_
}

///|
pub fn ExpansionPolicy::max_payload_bytes(self : ExpansionPolicy) -> Int32 {
  self.max_payload_bytes_
}

///|
pub fn ExpansionPolicy::max_depth(self : ExpansionPolicy) -> Int32 {
  self.max_depth_
}

///|
pub fn ExpansionPolicy::max_workflow_expansions(
  self : ExpansionPolicy,
) -> Int32 {
  self.max_workflow_expansions_
}

///|
pub fn ExpansionPolicy::max_workflow_tasks(self : ExpansionPolicy) -> Int32 {
  self.max_workflow_tasks_
}

///|
/// Immutable value snapshot of every bound. Previews embed it so an approval
/// binds the exact policy, not a mutable configuration cell.
pub(all) struct ExpansionPolicySnapshot {
  max_tasks : Int32
  max_edges : Int32
  max_deps_per_task : Int32
  max_key_chars : Int32
  max_title_chars : Int32
  max_description_chars : Int32
  max_dod_items : Int32
  max_dod_item_chars : Int32
  max_payload_bytes : Int32
  max_depth : Int32
  max_workflow_expansions : Int32
  max_workflow_tasks : Int32
} derive(Eq, Debug)

///|
pub extend ExpansionPolicySnapshot with Eq::{equal, not_equal}

///|
pub extend ExpansionPolicySnapshot with @debug.Debug::{to_repr}

///|
pub fn ExpansionPolicy::snapshot(
  self : ExpansionPolicy,
) -> ExpansionPolicySnapshot {
  {
    max_tasks: self.max_tasks_,
    max_edges: self.max_edges_,
    max_deps_per_task: self.max_deps_per_task_,
    max_key_chars: self.max_key_chars_,
    max_title_chars: self.max_title_chars_,
    max_description_chars: self.max_description_chars_,
    max_dod_items: self.max_dod_items_,
    max_dod_item_chars: self.max_dod_item_chars_,
    max_payload_bytes: self.max_payload_bytes_,
    max_depth: self.max_depth_,
    max_workflow_expansions: self.max_workflow_expansions_,
    max_workflow_tasks: self.max_workflow_tasks_,
  }
}

///|
/// Committed workflow usage from durable expansion history. Rejected proposals
/// consume their authorization capability but add no generated-task usage.
pub(all) struct ExpansionBudgetSnapshot {
  expansions_used : Int32
  max_expansions : Int32
  cumulative_tasks : Int32
  max_cumulative_tasks : Int32
} derive(Eq, Debug)

///|
pub extend ExpansionBudgetSnapshot with Eq::{equal, not_equal}

///|
pub extend ExpansionBudgetSnapshot with @debug.Debug::{to_repr}
