///|
/// Version string reported in thread sync payloads (`tool_version`).
const NMEM_TOOL_VERSION : String = "posoco-ext-nowledge-mem/0.1.0"

///|
/// Title is capped at the first 120 characters of the first user message
/// (upstream buildTitle).
const NMEM_TITLE_MAX_CHARS : Int = 120

///|
/// Thread id for a session: "{source_app}-{session_id}", lowercased, with
/// every run of characters outside [a-z0-9._-] replaced by a single "-"
/// (upstream threadIdFor).
pub fn thread_id(source_app : String, session_id : String) -> String {
  normalize_thread_id("\{source_app}-\{session_id}")
}

///|
/// Literal '-' characters are allowed and kept verbatim; only disallowed
/// runs collapse to a single '-'.
fn normalize_thread_id(raw : String) -> String {
  let lowered = raw.to_lower()
  let out : Array[Char] = []
  let mut pending_dash = false
  for ch in lowered {
    let allowed = (ch >= 'a' && ch <= 'z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '.' ||
      ch == '_' ||
      ch == '-'
    if allowed {
      if pending_dash {
        out.push('-')
        pending_dash = false
      }
      out.push(ch)
    } else {
      pending_dash = true
    }
  }
  if pending_dash {
    out.push('-')
  }
  String::from_array(out)
}

///|
/// Thread title: first 120 characters of the first user message. Posoco has
/// no session-name or cwd source here, so the fallback is the host label
/// derived from `source_app` (upstream: session name → first user message →
/// "{host} session - {cwd}").
pub fn thread_title(
  messages : Array[NmemThreadMessage],
  source_app : String,
) -> String {
  let mut first_user : String? = None
  for message in messages {
    if first_user is None && message.role is User {
      first_user = Some(message.content.trim().to_owned())
    }
  }
  match first_user {
    Some(content) =>
      if content != "" {
        take_prefix(content, NMEM_TITLE_MAX_CHARS)
      } else {
        "\{host_label(source_app)} session"
      }
    None => "\{host_label(source_app)} session"
  }
}

///|
/// A thread only syncs when it contains at least one user and one assistant
/// message (upstream shouldSync).
pub fn should_sync(messages : Array[NmemThreadMessage]) -> Bool {
  let mut has_user = false
  let mut has_assistant = false
  for message in messages {
    if message.role is User {
      has_user = true
    }
    if message.role is Assistant {
      has_assistant = true
    }
  }
  has_user && has_assistant
}

///|
/// Assemble the POST /threads request body (upstream buildSyncPayload).
/// `project` is still null: hosts do not pass a workspace root into this
/// extension. Since the workspace-anchoring milestone, `HostContext.cwd` is
/// the single cwd source (`WorkspaceAnchor`); threading it here is future
/// work.
pub fn build_thread_body(
  thread_id~ : String,
  title~ : String,
  messages~ : Array[NmemThreadMessage],
  config~ : NmemConfig,
  session_id~ : String,
  sync_reason~ : String,
) -> Json {
  let metadata : Map[String, Json] = {
    "session_id": Json::string(session_id),
    "sync_reason": Json::string(sync_reason),
  }
  match config.agent_id {
    Some(agent_id) => metadata["agent_id"] = Json::string(agent_id)
    None => ()
  }
  match config.host_agent_id {
    Some(host_agent_id) =>
      metadata["host_agent_id"] = Json::string(host_agent_id)
    None => ()
  }
  Json::object({
    "thread_id": Json::string(thread_id),
    "title": Json::string(title),
    "messages": Json::array(messages.map(m => m.to_wire_json())),
    "source": Json::string(config.source_app),
    "project": Json::null(),
    "tool_version": Json::string(NMEM_TOOL_VERSION),
    "metadata": Json::object(metadata),
  })
}

///|
/// Wire Json of one thread message, shared by the sync body and the
/// incremental fingerprint so both see the identical message shape.
fn NmemThreadMessage::to_wire_json(self : NmemThreadMessage) -> Json {
  Json::object({
    "role": Json::string(role_to_wire(self.role)),
    "content": Json::string(self.content),
    "metadata": Json::object(self.metadata),
  })
}

///|
fn role_to_wire(role : NmemRole) -> String {
  match role {
    User => "user"
    Assistant => "assistant"
    System => "system"
  }
}
