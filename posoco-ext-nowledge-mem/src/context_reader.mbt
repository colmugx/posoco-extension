///|
/// Cap on one recalled context payload (upstream MAX_CONTEXT_CHARS = 20_000)
/// — applies to the passively injected working memory and to the
/// `read_context_bundle` tool body alike.
const NMEM_MAX_CONTEXT_CHARS : Int = 20000

///|
/// Truncation tail note appended when a payload exceeds the cap (host label
/// derived from `source_app`).
fn context_truncation_note(source_app : String) -> String {
  "[Nowledge Mem context truncated by \{host_label(source_app)} plugin]"
}

///|
/// Cap a recalled context payload at NMEM_MAX_CONTEXT_CHARS and append the
/// truncation note (mirrors truncate_message's shape).
pub fn truncate_context(text : String, source_app : String) -> String {
  if text.length() <= NMEM_MAX_CONTEXT_CHARS {
    text
  } else {
    "\{take_prefix(text, NMEM_MAX_CONTEXT_CHARS)}\n\n\{context_truncation_note(source_app)}"
  }
}

///|
/// stdout as a JSON object without an "error" key, else None (upstream treats
/// an error envelope as a failed read).
fn clean_json_object(stdout : String) -> Map[String, Json]? {
  let parsed = @json.parse(stdout) catch { _ => return None }
  match parsed {
    Json::Object(fields) =>
      if fields.contains("error") {
        None
      } else {
        Some(fields)
      }
    _ => None
  }
}

///|
/// First non-empty string among `keys`.
fn first_string_field(
  fields : Map[String, Json],
  keys : Array[String],
) -> String? {
  for key in keys {
    match fields.get(key) {
      Some(Json::String(value)) =>
        if value.trim().length() > 0 {
          return Some(value)
        }
      _ => ()
    }
  }
  None
}

///|
/// Context-bundle payload: rendered_markdown, then markdown, then content.
fn parse_context_payload(stdout : String) -> String? {
  match clean_json_object(stdout) {
    Some(fields) =>
      first_string_field(fields, ["rendered_markdown", "markdown", "content"])
    None => None
  }
}
