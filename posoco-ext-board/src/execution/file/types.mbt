///|
pub(all) enum JournalFailure {
  BeforeRename
  AfterRename
} derive(Eq)

///|
pub extend JournalFailure with Eq::{equal, not_equal}
