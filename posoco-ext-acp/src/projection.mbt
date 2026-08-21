///|
/// Pure projection helpers: Posoco kernel values → ACP v1 wire values.
///
/// Everything in this file is a total function with no state and no IO, so
/// the bridge (`acp_bridge.mbt`) stays a thin state machine over these
/// translations and every mapping here is directly unit-testable.

///|
/// Strip one MCP-style `server__tool` namespace segment: the kind heuristic
/// matches on the tool's own name.
fn base_tool_name(name : String) -> String {
  match name.rev_find("__") {
    Some(at) => name[at + 2:].to_owned()
    None => name
  }
}

///|
/// Map a Posoco tool name onto the closest ACP `ToolKind`.
///
/// Exact un-namespaced names match first; otherwise the longest known verb
/// prefix wins (`search_issues` → `Search`). Anything unrecognized maps to
/// `Other`, which ACP clients render generically. Names here follow the tool
/// vocabulary of the posoco extension family (read/write/edit/bash/grep/
/// glob/...) plus the common aliases and compound names cetas hosts and MCP
/// servers are likely to expose.
pub fn acp_tool_kind(name : String) -> @acp.ToolKind {
  let base = base_tool_name(name)
  match base {
    "read" | "view" | "cat" | "open" | "ls" | "tree" | "list_dir" => Read
    "edit"
    | "write"
    | "apply_patch"
    | "patch"
    | "str_replace"
    | "insert"
    | "create_file" => Edit
    "delete" | "rm" | "remove" | "trash" => Delete
    "move" | "mv" | "rename" => Move
    "grep" | "glob" | "search" | "find" | "ripgrep" | "query" => Search
    "bash"
    | "sh"
    | "shell"
    | "exec"
    | "execute"
    | "run"
    | "terminal"
    | "command"
    | "cmd" => Execute
    "fetch" | "http" | "web" | "curl" | "browse" | "request" => Fetch
    "think" | "reason" | "reflect" => Think
    "switch_mode" | "set_mode" => SwitchMode
    _ => prefix_tool_kind(base)
  }
}

///|
/// Longest-verb-prefix fallback for compound tool names (`search_issues`,
/// `read_file`, `edit_document`). Longer prefixes are checked first so
/// `apply_patch_*` wins over `patch_*`.
fn prefix_tool_kind(base : String) -> @acp.ToolKind {
  let prefixes : Array[(String, @acp.ToolKind)] = [
    ("apply_patch", Edit),
    ("str_replace", Edit),
    ("create_file", Edit),
    ("list_dir", Read),
    ("ripgrep", Search),
    ("switch_mode", SwitchMode),
    ("set_mode", SwitchMode),
    ("read", Read),
    ("edit", Edit),
    ("write", Edit),
    ("patch", Edit),
    ("insert", Edit),
    ("delete", Delete),
    ("remove", Delete),
    ("trash", Delete),
    ("move", Move),
    ("rename", Move),
    ("grep", Search),
    ("glob", Search),
    ("search", Search),
    ("find", Search),
    ("query", Search),
    ("bash", Execute),
    ("shell", Execute),
    ("exec", Execute),
    ("execute", Execute),
    ("run", Execute),
    ("terminal", Execute),
    ("command", Execute),
    ("fetch", Fetch),
    ("http", Fetch),
    ("curl", Fetch),
    ("browse", Fetch),
    ("think", Think),
    ("reason", Think),
  ]
  // Longest match wins: scan by descending prefix length.
  let mut best : @acp.ToolKind? = None
  let mut best_length = 0
  for pair in prefixes {
    let (prefix, kind) = pair
    if prefix.length() > best_length && base.has_prefix(prefix) {
      best = Some(kind)
      best_length = prefix.length()
    }
  }
  match best {
    Some(kind) => kind
    None => Other
  }
}

///|
/// Argument keys that usually carry the human-meaningful operand of a tool
/// call, in priority order. Used only for the client-visible title; nothing
/// downstream depends on the extraction succeeding.
let primary_arg_keys : Array[String] = [
  "path", "file_path", "filePath", "filename", "file", "command", "cmd", "query",
  "pattern", "url", "uri", "name", "dir", "directory", "root",
]

///|
/// Extract the first string-valued primary argument from parsed tool-call
/// arguments, if any.
pub fn acp_primary_arg(arguments : Json) -> String? {
  match arguments {
    Object(fields) => {
      for key in primary_arg_keys {
        match fields.get(key) {
          Some(String(value)) => if value != "" { return Some(value) }
          _ => ()
        }
      }
      None
    }
    _ => None
  }
}

///|
/// One-line client-visible title for a tool call, e.g. `read(src/main.mbt)`.
/// The operand passes through `sanitize_label` so paths and commands are
/// collapsed to a bounded single-line label.
pub fn acp_tool_title(call : @posoco.ToolCall) -> String {
  acp_title(call.name.to_string(), call.arguments)
}

///|
/// `acp_tool_title` from raw parts — approval asks carry the parsed fields
/// (`ApprovalRequest`), not the originating ToolCall.
fn acp_title(name : String, arguments : Json) -> String {
  match acp_primary_arg(arguments) {
    Some(arg) => "\{name}(\{@devkit.sanitize_label(arg, limit=48)})"
    None => name
  }
}

///|
/// Map one Posoco content block onto an ACP content block.
/// `Text` is the common case; `Image` carries the provider's media type and
/// opaque payload verbatim (the kernel never interprets image data).
pub fn acp_content_block(content : @posoco.Content) -> @acp.ContentBlock {
  match content {
    Text(text) => Text({ annotations: Omitted, text, meta: Omitted })
    Image(media_type~, data~) =>
      Image({
        annotations: Omitted,
        data,
        mime_type: media_type,
        uri: Omitted,
        meta: Omitted,
      })
  }
}

///|
/// Terminal ACP status for a Posoco tool outcome. Any non-success outcome is
/// `Failed` — the variant tag is the error status (kernel single-sourcing).
pub fn acp_outcome_status(outcome : @posoco.ToolOutcome) -> @acp.ToolCallStatus {
  match outcome {
    Success(..) => Completed
    _ => Failed
  }
}

///|
/// Client-visible text mirror of a tool outcome, carried as the completed
/// tool call's content. Tool-reported text passes through unchanged (the
/// model sees the same text); adapter-level failures are sanitized to a
/// bounded single-line label so raw error payloads never reach the client.
pub fn acp_outcome_text(outcome : @posoco.ToolOutcome) -> String {
  match outcome {
    Success(content~, ..) => content
    ToolReportedError(content~, ..) => content
    RuntimeFailure(error_category~, message~) =>
      "[\{error_category}] \{@devkit.sanitize_label(message)}"
    NotExecuted(reason~, ..) => "not executed: \{reason.to_string()}"
  }
}

///|
/// ACP stop reason for a finished turn, derived from the last assistant
/// finish reason the bridge observed. `Length` is the only finish reason
/// with a distinct ACP meaning (`MaxTokens`); everything else means the turn
/// ran to its natural end.
pub fn acp_stop_reason(finish : @posoco.FinishReason?) -> @acp.StopReason {
  match finish {
    Some(Length) => MaxTokens
    _ => EndTurn
  }
}
