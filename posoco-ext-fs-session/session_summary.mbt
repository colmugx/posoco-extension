///|
/// session_summary.mbt — lightweight session metadata for host UIs (session
/// pickers, title bars) that must not parse full journals themselves.

///|
/// What hosts need to title a session: the metadata `name` when the user
/// named it, else a prefix of the first user message, else the raw id.
pub(all) struct SessionSummary {
  id : String
  name : String?
  first_user_text : String
} derive(Eq, Debug)

///|
/// Read one session and project it to a summary. The store's own load rules
/// apply, so a missing file yields an empty summary (no name, no first user
/// text) and `display_title` falls back to the id — the same
/// missing-means-empty contract `SessionStore::load` sets.
pub async fn JsonlSessionStore::summary(
  self : JsonlSessionStore,
  id : String,
) -> SessionSummary raise @posoco.SessionError {
  let session = self.load(id)
  let name = match session.metadata.get("name") {
    Some(Json::String(s)) => Some(s)
    _ => None
  }
  let mut first_user_text = ""
  for msg in session.messages {
    match msg {
      @posoco.Message::UserMessage(content~) => {
        let buf = StringBuilder()
        for item in content {
          match item {
            @posoco.Content::Text(text) => buf.write_string(text)
            @posoco.Content::Image(..) => ()
          }
        }
        first_user_text = buf.to_string()
        break
      }
      _ => ()
    }
  }
  { id, name, first_user_text, }
}

///|
/// Host-facing title: the user-chosen name wins; otherwise the first user
/// text with whitespace runs collapsed (leading/trailing included), cut at
/// 50 chars; when neither exists, the session id.
pub fn display_title(s : SessionSummary) -> String {
  match s.name {
    Some(name) if name.length() > 0 => name
    _ => {
      let collapsed = collapse_whitespace(s.first_user_text)
      if collapsed.length() == 0 {
        s.id
      } else {
        @devkit.truncate_chars(collapsed, 50)
      }
    }
  }
}

///|
/// Collapse whitespace runs to single spaces and drop the leading/trailing
/// ones, so a wrapped multi-line first message becomes one clean title line.
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
