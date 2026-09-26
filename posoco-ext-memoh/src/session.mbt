///|
/// Load always returns a fresh empty Posoco session.
///
/// Memoh owns the durable conversation and supplies the current host context
/// independently for each turn. Returning a previous Posoco transcript here
/// would create a second conversation authority and make retry/edit/restart
/// semantics diverge from the host.
pub impl @posoco.SessionStore for Memoh with fn load(
  _self : Memoh,
  _id : String,
) -> @posoco.Session raise @posoco.SessionError {
  @posoco.Session::{ messages: [], metadata: Map::from_array([]), }
}

///|
/// Ignore whole-session saves. Memoh persists the conversation itself.
pub impl @posoco.SessionStore for Memoh with fn save(
  _self : Memoh,
  _id : String,
  _session : @posoco.Session,
) -> Unit raise @posoco.SessionError {
  ()
}

///|
/// Ignore append saves explicitly rather than falling back to the generic
/// load-concatenate-save implementation.
pub impl @posoco.SessionStore for Memoh with fn append_messages(
  _self : Memoh,
  _id : String,
  _from_index : Int,
  _messages : ArrayView[@posoco.Message],
) -> Unit raise @posoco.SessionError {
  ()
}

///|
/// Ignore atomic checkpoint persistence explicitly. Memoh owns the durable
/// transcript and metadata; even checkpoint-style commits must never create a
/// second conversation authority inside the hosted agent.
pub impl @posoco.SessionStore for Memoh with fn checkpoint(
  _self : Memoh,
  _id : String,
  _checkpoint : @posoco.SessionCheckpoint,
) -> Unit raise @posoco.SessionError {
  ()
}

///|
/// Ignore transcript truncation explicitly. Retry/edit/reset semantics are
/// owned by Memoh, not by a local Posoco transcript.
pub impl @posoco.SessionStore for Memoh with fn truncate(
  _self : Memoh,
  _id : String,
  _from_index : Int,
) -> Unit raise @posoco.SessionError {
  ()
}

///|
pub extend Memoh with @posoco.SessionStore::{
  load,
  save,
  append_messages,
  checkpoint,
  truncate,
}
