///|
/// Default project-local persistence for `.handoff/HANDOFF.md`.
///
/// Target-specific implementations live in `default_store.native.mbt` and
/// `default_store.js.mbt`. Both use a sibling temporary file followed by
/// rename so a failed write does not truncate an existing handoff document.
pub struct DefaultHandoffStore {}

///|
pub fn DefaultHandoffStore::new() -> DefaultHandoffStore {
  DefaultHandoffStore::{  }
}
