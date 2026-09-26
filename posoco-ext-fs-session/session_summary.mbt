///|
/// session_summary.mbt — lightweight session metadata for host UIs (session
/// pickers, title bars) that must not parse full journals themselves.

///|
/// Host-facing session identity. `name` is an explicit user/product rename;
/// `title` is the stable automatic title admitted by Posoco from the first
/// real caller input. For sessions written before `posoco.title` existed,
/// `summary` derives a legacy title from the first user-role message.
pub(all) struct SessionSummary {
  id : String
  name : String?
  title : String?
} derive(Eq, Debug)

///|
pub extend SessionSummary with Eq::{not_equal, equal}

///|
pub extend SessionSummary with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Read one session and project it to presentation metadata.
///
/// New sessions use `metadata[@posoco.SESSION_TITLE_METADATA_KEY]`; transcript
/// roles are not consulted for their normal title. The first-user scan is only
/// a compatibility fallback for journals created before that metadata contract.
pub async fn JsonlSessionStore::summary(
  self : JsonlSessionStore,
  id : String,
) -> SessionSummary raise @posoco.SessionError {
  let session = self.load(id)
  let name = match session.metadata.get("name") {
    Some(Json::String(s)) if !s.is_empty() => Some(s)
    _ => None
  }
  let title = match session.metadata.get(@posoco.SESSION_TITLE_METADATA_KEY) {
    Some(Json::String(s)) => normalize_title(s)
    _ => legacy_title_from_messages(session.messages)
  }
  { id, name, title, }
}

///|
/// Host-facing title. Explicit naming wins over the automatic session title;
/// missing/empty presentation metadata falls back to the raw session id.
pub fn display_title(s : SessionSummary) -> String {
  match s.name {
    Some(name) if !name.is_empty() => name
    _ =>
      match s.title {
        Some(title) if !title.is_empty() => title
        _ => s.id
      }
  }
}

///|
/// Compatibility only: historical sessions have no `posoco.title`, so retain
/// the old first-user heuristic when reading them. This is deliberately kept
/// behind the summary projection and is not the contract for new sessions.
fn legacy_title_from_messages(messages : Array[@posoco.Message]) -> String? {
  for msg in messages {
    match msg {
      @posoco.Message::UserMessage(content~) => {
        let buf = StringBuilder()
        for item in content {
          match item {
            @posoco.Content::Text(text) => buf.write_string(text)
            @posoco.Content::Image(..) => ()
          }
        }
        return normalize_title(buf.to_string())
      }
      _ => ()
    }
  }
  None
}

///|
fn normalize_title(s : String) -> String? {
  let collapsed = collapse_whitespace(s)
  if collapsed.is_empty() {
    None
  } else {
    Some(@devkit.truncate_chars(collapsed, 50))
  }
}

///|
/// Collapse whitespace runs to single spaces and drop the leading/trailing
/// ones, so presentation metadata stays one clean title line.
fn collapse_whitespace(s : String) -> String {
  let builder = StringBuilder()
  let mut pending_space = false
  let mut written = 0
  for ch in s {
    let code = ch.to_int()
    if code == 0x20 || code == 0x09 || code == 0x0a || code == 0x0d {
      pending_space = true
    } else {
      if pending_space && written > 0 {
        builder.write_char(' ')
        written += 1
      }
      pending_space = false
      builder.write_char(ch)
      written += 1
    }
  }
  builder.to_string()
}
