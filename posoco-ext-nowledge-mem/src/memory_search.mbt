///|
/// Timeout for one port `search` (the `memory_search` MCP call) — off the
/// model-call path, so it uses the full tool budget.
const NMEM_MEMORY_SEARCH_TIMEOUT_MS : Int = 30000

///|
/// Render the server's `memory_search` reply as provider text: one
/// `- [id] content` line per memory (id omitted when the server gives
/// none), a non-JSON reply degrades to its trimmed raw text, and an empty
/// page is a clean miss (`None` — no hits).
fn search_reply_text(text : String) -> String? {
  match clean_json_object(text) {
    Some(fields) =>
      match fields.get("memories") {
        Some(Json::Array(items)) => {
          let lines : Array[String] = []
          for item in items {
            match item {
              Json::Object(item_fields) =>
                match item_fields.get("content") {
                  Some(Json::String(content)) =>
                    match item_fields.get("id") {
                      Some(Json::String(id)) =>
                        lines.push("- [\{id}] \{content}")
                      _ => lines.push("- \{content}")
                    }
                  // An item without string content is unusable and skipped.
                  _ => ()
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
/// Retrieval side of `MemoryPort`: real search against the server's
/// `memory_search` surface. `top_k` maps to the server's `limit` (omitting
/// it leaves the hit count to the server); core renders whatever text the
/// provider returns. Failures raise `MemoryError::Search` (recorded on
/// `mem.last_error`, visible via `/memory status`).
pub impl @posoco.MemoryPort for NowledgeMem with fn search(
  self : NowledgeMem,
  query~ : String,
  top_k? : Int,
) -> String? raise @posoco.MemoryError {
  let fields : Map[String, Json] = { "query": Json::string(query) }
  match top_k {
    Some(k) => fields["limit"] = Json::number(k.to_double())
    None => ()
  }
  let outcome : Result[McpCallOutcome, String]? = try
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
    Some(Err(message)) => {
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
