///|
/// `bash_events` — the advisory shell-session notifications this package
/// publishes, on the same `@events` channel as every other cross-extension
/// fact (see `extension/docs/events-migration.md`).
///
/// Before the migration these rode the retired devkit event bus as three
/// string topics (`bash.session.started`, `bash.session.finished`,
/// `bash.session.stall`) carrying a Json session snapshot. Those topics were
/// never part of the closed `@kit_events` protocol (no in-tree subscriber
/// exists, and the payload is a live snapshot rather than a fixed record),
/// so the constructor is defined here — its defining package — and the
/// legacy topic name survives as the payload's `kind`. Semantics are
/// unchanged: fire-and-forget, advisory only, never an error path, and the
/// snapshot object is byte-for-byte what `ShellSession::snapshot` produced.

///|
/// The legacy topic names this package used to publish on, now payload
/// values. A subscriber was already selecting one of these three, so the
/// vocabulary is preserved verbatim.
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
