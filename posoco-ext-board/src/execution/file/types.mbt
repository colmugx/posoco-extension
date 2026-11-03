///|
#derive(Eq)
pub(all) enum JournalFailure {
  BeforeRename
  AfterRename
}

///|
pub extend JournalFailure with Eq::{equal, not_equal}
