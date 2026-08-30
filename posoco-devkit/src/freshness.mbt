///|
/// Identity of a file at the moment it was read.
///
/// The read/write/edit tools record a stamp at read time and compare it
/// against a fresh stat of the same path before modifying it, so a write
/// never silently clobbers content that changed after the model last saw it.
/// `mtime_s`/`mtime_ns` are the (seconds, nanoseconds) pair surfaced by
/// `@fs.mtime` on native and by `statSync` on js; `size` is the file length
/// in bytes.
pub(all) struct FileStamp {
  mtime_s : Int64
  mtime_ns : Int
  size : Int64
} derive(Eq, Debug)

///|
/// Outcome of checking a modification target against a `FreshnessGuard`.
pub(all) enum FreshnessVerdict {
  Fresh
  NeverRead
  Modified
} derive(Eq, Debug)

///|
/// Read-before-modify ledger shared by the read/write/edit tool extensions.
///
/// One guard instance per composed Agent: the host creates it and injects it
/// into all three tools, so a `read` in one tool is visible to `write`/`edit`
/// in the others. The guard itself touches no IO — callers stat files and
/// pass stamps in. Its granularity is the Agent lifetime, matching the
/// session cache of `posoco-ext-permission`.
pub struct FreshnessGuard {
  records : Map[String, FileStamp]
}

///|
pub fn FreshnessGuard::FreshnessGuard() -> FreshnessGuard {
  { records: {}, }
}

///|
/// Record that `path` was successfully read with identity `stamp`.
pub fn FreshnessGuard::note_read(
  self : FreshnessGuard,
  path : String,
  stamp : FileStamp,
) -> Unit {
  self.records[path] = stamp
}

///|
/// Drop any recorded read for `path` (e.g. after the file was rewritten).
pub fn FreshnessGuard::forget(self : FreshnessGuard, path : String) -> Unit {
  ignore(self.records.remove(path))
}

///|
/// Classify a modification target against the guard.
///
/// `current` is a stat of the file as it exists now. `None` means the path
/// does not exist, in which case creating it is always allowed — a new file
/// cannot have been clobbered.
pub fn FreshnessGuard::check(
  self : FreshnessGuard,
  path : String,
  current : FileStamp?,
) -> FreshnessVerdict {
  match current {
    None => Fresh
    Some(now) =>
      if self.records.contains(path) {
        if self.records[path] == now {
          Fresh
        } else {
          Modified
        }
      } else {
        NeverRead
      }
  }
}

///|
/// Plain-language hint for a non-fresh verdict, for tool error messages.
#as_free_fn(freshness_hint, visibility="pub", deprecated="use `FreshnessVerdict::hint` instead")
pub fn FreshnessVerdict::hint(self : FreshnessVerdict) -> String {
  match self {
    Fresh => "file is current"
    NeverRead =>
      "file exists but has not been read in this session; read it first"
    Modified => "file changed since it was last read; read it again"
  }
}
