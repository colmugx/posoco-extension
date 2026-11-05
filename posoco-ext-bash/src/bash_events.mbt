///|
/// `bash_events` — the advisory shell-session notifications this package
/// publishes, on the same `@events` channel as every other cross-extension
/// fact.
///
/// There are three lifecycle facts (`bash.session.started`,
/// `bash.session.finished`, `bash.session.stall`), each carrying a Json
/// session snapshot. They are not part of the closed `@kit_events` protocol —
/// no in-tree subscriber exists, and the payload is a live snapshot rather
/// than a fixed record — so the constructor is defined here, its defining
/// package, and the lifecycle fact travels as the payload's `kind`.
/// Fire-and-forget, advisory only, never an error path; the snapshot object is
/// exactly what `ShellSession::snapshot` produces.

///|
/// The `kind` values this package publishes. A subscriber selects on one of
/// these three, so the vocabulary is part of the contract and stays verbatim.
pub const BASH_SESSION_STARTED : String = "bash.session.started"

///|
pub const BASH_SESSION_FINISHED : String = "bash.session.finished"

///|
pub const BASH_SESSION_STALL : String = "bash.session.stall"

///|
/// One advisory session notification: which lifecycle fact (`kind`, one of
/// the `BASH_SESSION_*` constants) plus the session snapshot at emission
/// time.
#derive(Debug)
pub(all) struct BashSessionNoticePayload {
  kind : String
  snapshot : Json
}

///|
pub extend BashSessionNoticePayload with @moonbitlang/core/debug.Debug::{
  to_repr,
}

///|
/// The shell-session notification constructor. Publishers inside this
/// package publish it through an owner-bound capability
/// (`system.publisher(owner="posoco_ext_bash")`), so the envelope carries
/// `Extension("posoco_ext_bash")` and subscribers need no payload field for
/// the publisher identity.
pub(all) extenum @events.Event += {
  BashSessionNotice(BashSessionNoticePayload)
}
