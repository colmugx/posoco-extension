///|
/// Small in-memory implementation of `HandoffWorkSource` for products that do
/// not already have planner/task state to adapt.
///
/// It is deliberately not a Posoco port or extension. The product owns this
/// value and updates it as work advances; `/handoff create` only snapshots it.
pub struct HandoffWorkState {
  mut work : WorkSnapshot
}

///|
fn copy_work(work : WorkSnapshot) -> WorkSnapshot {
  {
    objective: work.objective,
    done_when: