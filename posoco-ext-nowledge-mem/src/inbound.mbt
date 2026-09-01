///|
/// Namespace of this extension's context envelopes — plugin-level, never the
/// host's product name (`<nmem-context>`), the same ownership rule as
/// permission's `<permission-context>` and plan's `<plan-context>`. The
/// envelope this extension renders inside its `MemoryPort::inbound` body
/// carries it.
const NMEM_CONTEXT_NS : String = "nmem"

///|
/// Timeout for the one-shot session-inbound working-memory read — it sits on
/// the model-call path, so it fails faster than the tool budget.
const NMEM_INBOUND_READ_TIMEOUT_MS : Int = 5000

///|
/// Working-memory payload as an inbound body: a clean JSON object honours
/// `exists:false` and `content`; unparseable text degrades to the trimmed
/// raw text; anything else is a clean miss (`None` — nothing to inject).
fn wm_snapshot_content(text : String) -> String? {
  match clean_json_object(text) {
    Some(fields) =>
      if fields.get("exists") is Some(Json::False) {
        None
      } else {
        first_string_field(fields, ["content"])
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
/// Read the working-memory snapshot once, best-effort: the same
/// `read_working_memory` MCP surface the inbound slot fronts. `Ok(None)` is
/// empty working memory, `Ok(Some)` carries the content, and `Err(reason)` is
/// a failure with the reason already recorded on `mem.last_error` (visible
/// through `/memory status`). Never raises: a failed read must not break the
/// turn.
async fn NowledgeMem::read_working_memory_snapshot(
  self : NowledgeMem,
) -> Result[String?, String] noraise {
  let outcome : Result[McpCallOutcome, String]? = try
    self.mcp.call_tool(
      "read_working_memory",
      mcp_args(self.config, Map([]), identity=true),
      timeout_ms=NMEM_INBOUND_READ_TIMEOUT_MS,
    )
  catch {
    _ => None
  } noraise {
    value => Some(value)
  }
  let reason = match outcome {
    None => "mcp call raised"
    Some(Err(message)) => message
    Some(Ok({ is_error: true, text, })) =>
      take_prefix(text, NMEM_TOOL_ERROR_CHARS)
    Some(Ok({ text, .. })) => return Ok(wm_snapshot_content(text))
  }
  self.mem.last_error = Some("inbound read failed: \{reason}")
  Err(reason)
}

///|
/// Whether a message is core's injected session-opening memory message —
/// recognized by core's fixed lead line, format-neutral. The sync mapper
/// filters the whole message back out (this extension's envelope rides
/// inside it).
fn is_injected_memory_message(message : @posoco.Message) -> Bool {
  match message {
    @posoco.Message::UserMessage(content~) =>
      match content {
        [@posoco.Content::Text(text), ..] =>
          text.has_prefix(@posoco.MEMORY_INBOUND_LEAD)
        _ => false
      }
    _ => false
  }
}

///|
/// MemoryPort inbound view: the session-opening memory body — core injects
/// it verbatim behind its own lead line (which already opens the memory
/// section), so the provider owns the whole body format. This extension
/// wraps the working-memory snapshot (capped by the context limit) in its
/// plugin-level `<nmem-context type="memory" trust="false">` envelope: the
/// namespace is this extension's identity (never the host's product name),
/// and `trust="false"` marks recalled memory as possibly stale. `None`
/// (empty read) or a raise (failed read — reason recorded on
/// `mem.last_error`) spends core's once-per-session attempt for this
/// process; core turns the raise into a secondary-failure event and the turn
/// continues without this provider's content.
pub impl @posoco.MemoryPort for NowledgeMem with fn inbound(
  self : NowledgeMem,
  session_id~ : String,
  request~ : String,
) -> String? raise @posoco.MemoryError {
  ignore(session_id)
  ignore(request)
  match self.read_working_memory_snapshot() {
    Ok(None) => None
    Ok(Some(content)) => {
      let source_app = match self.config {
        Some(config) => config.source_app
        None => self.source_app
      }
      Some(
        @devkit.context_envelope(
          ns=NMEM_CONTEXT_NS,
          kind="memory",
          trust=false,
          content=truncate_context(content, source_app),
        ),
      )
    }
    Err(reason) => raise @posoco.MemoryError::Inbound(reason)
  }
}

///|
pub extend NowledgeMem with @posoco.MemoryPort::{inbound}
