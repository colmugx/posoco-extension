///|
/// Nominal Board identifiers. Task and attempt ids are distinct types, so
/// neither can be confused with the other or with a raw string.
pub struct BoardTaskId {
  value : String
} derive(Eq, Hash, Debug)

///|
pub fn BoardTaskId::BoardTaskId(value : String) -> BoardTaskId {
  { value, }
}

///|
pub extend BoardTaskId with Eq::{equal, not_equal}

///|
pub extend BoardTaskId with Hash::{hash, hash_combine}

///|
pub extend BoardTaskId with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub struct AttemptId {
  value : String
} derive(Eq, Hash, Debug)

///|
pub fn AttemptId::AttemptId(value : String) -> AttemptId {
  { value, }
}

///|
pub extend AttemptId with Eq::{equal, not_equal}

///|
pub extend AttemptId with Hash::{hash, hash_combine}

///|
pub extend AttemptId with @moonbitlang/core/debug.Debug::{to_repr}
