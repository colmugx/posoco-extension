///|
/// Timeout for one port `search` (the `memory_search` MCP call) — off the
/// model-call path, so it uses the full tool budget.
const NMEM_MEMORY_SEARCH_TIMEOUT_MS : Int = 30000

///|
/// Render the server's `memory_search` reply as provider text: one
/// `- [id] content` line per hit (id omitted when the server gives none,
/// truncated previews point at their `reference_uri`), a non-JSON reply
/// degrades to its trimmed raw text, and an empty page is a clean miss
/// (`None` — no hits).
fn search_reply_text(text : String) -> String? {
  match clean_json_object(text) {
    Some(fields) =>
      match fields.get("results") {
        Some(Json::Array(items)) => {
          let lines : Array[String] = []
          for item in items {
            match item {
              Json::Object(item_fields) =>
                match search_item_line(item_fields) {
                  Some(line) => lines.push(line)
                  None => ()
                }
              _ => ()
            }
          }
          if lines.is_empty() {
            None
          } else {
            Some(lines.join("\n"))
          }
        }
        _ => None
      }
    None =>
      if text.trim().length() > 0 {
        Some(text.trim().to_owned())
      } else {
        None
      }
  }
}

///|
/// One `results` item as a `- [id] content` line. An item without string
/// content is unusable (`None`); `content_truncated` with a `reference_uri`
/// appends the deep-read pointer (the server bounds previews server-side).
fn search_item_line(fields : Map[String, Json]) -> String? {
  guard fields.get("content") is Some(Json::String(content)) else {
    return None
  }
  let mut line = match fields.get("id") {
    Some(Json::String(id)) => "- [\{id}] \{content}"
    _ => "- \{content}"
  }
  if fields.get("content_truncated") is Some(Json::True) {
    match fields.get("reference_uri") {
      Some(Json::String(uri)) => line = line + " …[full: \{uri}]"
      _ => ()
    }
  }
  Some(line)
}

///|
/// Retrieval side of `MemoryPort`: real search against the server's
/// `memory_search` surface. `top_k` maps to the server's `limit` (omitting
/// it leaves the hit count to the server); core renders whatever text the
/// provider returns. Failures raise `MemoryError::Search` (recorded on
/// `mem.last_error`, visible via `/memory status`). Attach gate: an
/// unattached composition is network- and config-inert, so retrieval is an
/// empty result.
pub impl @posoco.MemoryPort for NowledgeMem with fn search(
  self : NowledgeMem,
  query~ : String,
  top_k? : Int,
) -> String? raise @posoco.MemoryError {
  if !self.attached || self.config is None {
    return None
  }
  let fields : Map[String, Json] = { "query": Json::string(query) }
  match top_k {
    Some(k) => fields["limit"] = Json::number(k.to_double())
    None => ()
  }
  let outcome : Result[McpCallOutcome, NmemCallError]? = try
    self.mcp.call_tool(
      "memory_search",
      mcp_args(self.config, fields, identity=true),
      timeout_ms=NMEM_MEMORY_SEARCH_TIMEOUT_MS,
    )
  catch {
    _ => None
  } noraise {
    value => Some(value)
  }
  match outcome {
    None => {
      self.mem.last_error = Some("memory search failed: mcp call raised")
      raise @posoco.MemoryError::Search("mcp call raised")
    }
    Some(Err(err)) => {
      let message = err.message()
      self.mem.last_error = Some("memory search failed: " + message)
      raise @posoco.MemoryError::Search(message)
    }
    Some(Ok({ is_error: true, text, })) => {
      let reason = take_prefix(text, NMEM_TOOL_ERROR_CHARS)
      self.mem.last_error = Some("memory search failed: \{reason}")
      raise @posoco.MemoryError::Search(reason)
    }
    Some(Ok({ text, .. })) => search_reply_text(text)
  }
}

///|
pub extend NowledgeMem with @posoco.MemoryPort::{search, delete, store}
