///|
/// Timeout for the one-shot passive working-memory read — passive retrieval
/// sits on the model-call path, so it fails faster than the tool budget.
const NMEM_PASSIVE_READ_TIMEOUT_MS : Int = 5000

///|
/// Timeout for one queued write-back (`memory_add` / `memory_delete`) during
/// drain.
const NMEM_MEMORY_OP_TIMEOUT_MS : Int = 30000

///|
/// Prefix marking a store ticket whose write-back has not been acknowledged
/// yet (D8): `delete` recognizes it and drops the queued `Add` instead of
/// issuing a remote delete.
const NMEM_PENDING_PREFIX : String = "pending:"

///|
/// One queued write-back operation (D8 write-after queue). `Add` carries the
/// pending ticket plus the staged entry; `Delete` targets a remote id.
pub(all) enum MemoryOp {
  Add(pending_id~ : String, entry~ : @posoco.MemoryEntry)
  Delete(id~ : String)
} derive(Debug)

///|
/// Write-after queue state (D8): `queue` holds the writes the drain replays
/// against the MCP tools. Only the drain coroutine and the sync MemoryPort
/// slots touch this state; the sync slots only append, so no locking is
/// needed (R7).
pub(all) struct MemoryState {
  queue : Array[MemoryOp]
  mut last_error : String?
  mut next_pending : Int
}

///|
pub fn MemoryState::MemoryState() -> MemoryState {
  { queue: [], last_error: None, next_pending: 0, }
}

///|
/// Store through the write-after queue: queue the `Add` for the drain and
/// return the pending ticket synchronously. Pure memory work — no IO can
/// appear in this slot (D8).
pub impl @posoco.MemoryPort for NowledgeMem with fn store(
  self : NowledgeMem,
  entry : @posoco.MemoryEntry,
) -> String raise @posoco.MemoryError {
  self.mem.next_pending = self.mem.next_pending + 1
  let pending_id = "\{NMEM_PENDING_PREFIX}\{self.mem.next_pending}"
  self.mem.queue.push(Add(pending_id~, entry~))
  pending_id
}

///|
/// One-shot gated working-memory read (D9/M10): the first call of the
/// process run ignores the query entirely and reads the Nowledge Mem
/// working memory — the `read_working_memory` MCP tool, the same surface the
/// tool exposes — and core's MemoryRetrievalHook renders it as the "Any
/// Memory About This Work" section that persists for the session (a later
/// hit replaces it in place). Every later call returns `[]` without touching
/// the server: recall past the startup read is the model's job, via the
/// `memory_search` tool. The gate is spent before the attempt, so a failure
/// also exhausts it; raising is the intended observability path — core's
/// `search_all` catches the raise and reports it as a secondary-failure
/// observer event. A resumed process starts with a fresh gate, so its first
/// call re-reads and core swaps the old section for the new content.
pub impl @posoco.MemoryPort for NowledgeMem with fn search(
  self : NowledgeMem,
  _query : @posoco.MemoryQuery,
) -> Array[@posoco.MemoryEntry] raise @posoco.MemoryError {
  if self.passive_read_done {
    return []
  }
  self.passive_read_done = true
  let fields : Map[String, Json] = Map([])
  let outcome : Result[McpCallOutcome, String]? = try
    self.mcp.call_tool(
      "read_working_memory",
      mcp_args(self.config, fields, identity=true),
      timeout_ms=NMEM_PASSIVE_READ_TIMEOUT_MS,
    )
  catch {
    _ => None
  } noraise {
    value => Some(value)
  }
  let outcome = match outcome {
    None => {
      self.mem.last_error = Some("working memory read failed: mcp call raised")
      raise @posoco.MemoryError::Search("working memory read raised")
    }
    Some(outcome) => outcome
  }
  match outcome {
    Err(message) => {
      self.mem.last_error = Some("working memory read failed: " + message)
      raise @posoco.MemoryError::Search("working memory read failed")
    }
    Ok({ is_error: true, text, }) => {
      self.mem.last_error = Some(
        "working memory read failed: \{take_prefix(text, NMEM_TOOL_ERROR_CHARS)}",
      )
      raise @posoco.MemoryError::Search("working memory read reported an error")
    }
    Ok({ text, .. }) =>
      // The server returns the CLI's --json payload as text
      // (exists/content), so the JSON contract carries over; a server that
      // renders plain text degrades to treating the text as the content.
      match clean_json_object(text) {
        Some(fields) =>
          // `exists: false` or a clean object without usable content is an
          // empty working memory — a clean state, not a failure.
          if fields.get("exists") is Some(Json::False) {
            []
          } else {
            match first_string_field(fields, ["content"]) {
              Some(content) => [self.wm_entry(content)]
              None => []
            }
          }
        None =>
          if text.trim().length() > 0 {
            [self.wm_entry(text.trim().to_owned())]
          } else {
            []
          }
      }
  }
}

///|
/// The working-memory read as one MemoryEntry: `kind` marks it as the
/// server-managed briefing rather than a deletable distilled memory, and
/// the content carries the 20k recall cap so a runaway working memory
/// cannot bloat every model call.
fn NowledgeMem::wm_entry(
  self : NowledgeMem,
  content : String,
) -> @posoco.MemoryEntry {
  let source_app = match self.config {
    Some(config) => config.source_app
    None => self.source_app
  }
  {
    id: "wm",
    content: truncate_context(content, source_app),
    metadata: Map::from_array([("kind", Json::string("working_memory"))]),
    score: None,
  }
}

///|
/// Delete through the write-after queue: an empty id is rejected; a pending
/// ticket never reached the server, so dropping its queued `Add` is the whole
/// operation; a real id queues the remote delete for the drain. The server
/// is the single source of truth — there is no local replica to evict.
pub impl @posoco.MemoryPort for NowledgeMem with fn delete(
  self : NowledgeMem,
  id : String,
) -> Unit raise @posoco.MemoryError {
  if id == "" {
    raise @posoco.MemoryError::Delete("empty id")
  }
  if id.has_prefix(NMEM_PENDING_PREFIX) {
    drop_queued_add(self.mem, id)
  } else {
    self.mem.queue.push(Delete(id~))
  }
}

///|
/// Self-described provenance for core's memory-injection provenance line:
/// recalled entries render under "from Nowledge Mem. For Your Information.".
pub impl @posoco.MemoryPort for NowledgeMem with fn source_name(
  _self : NowledgeMem,
) -> String {
  "Nowledge Mem"
}

///|
pub extend NowledgeMem with @posoco.MemoryPort::{
  store,
  search,
  delete,
  source_name,
}

///|
/// Drop a queued `Add` whose pending ticket was deleted before flush.
fn drop_queued_add(state : MemoryState, target : String) -> Unit {
  let mut i = 0
  while i < state.queue.length() {
    match state.queue[i] {
      Add(pending_id~, ..) =>
        if pending_id == target {
          ignore(state.queue.remove(i))
        } else {
          i = i + 1
        }
      _ => i = i + 1
    }
  }
}

///|
/// Arguments for one queued `Add`, mapping the metadata convention keys to
/// the `memory_add` tool's properties (title / unit_type / importance /
/// labels). Ambient identity rides the call so writes are attributed to the
/// host product.
fn memory_add_mcp_args(
  entry : @posoco.MemoryEntry,
  config : NmemConfig?,
) -> Json {
  let fields : Map[String, Json] = { "content": Json::string(entry.content) }
  match entry.metadata.get("title") {
    Some(Json::String(title)) => fields["title"] = Json::string(title)
    _ => ()
  }
  match entry.metadata.get("unit_type") {
    Some(Json::String(unit_type)) =>
      fields["unit_type"] = Json::string(unit_type)
    _ => ()
  }
  match entry.metadata.get("importance") {
    Some(Json::Number(value, ..)) => fields["importance"] = Json::number(value)
    _ => ()
  }
  match entry.metadata.get("labels") {
    Some(Json::Array(items)) => {
      let labels : Array[Json] = []
      for item in items {
        match item {
          Json::String(label) => labels.push(Json::string(label))
          _ => ()
        }
      }
      fields["labels"] = Json::array(labels)
    }
    _ => ()
  }
  mcp_args(config, fields, identity=true)
}

///|
/// Flush one queued `Add`: call `memory_add` and treat the server's own
/// error flag as the failure signal. Any failure re-enqueues at the queue
/// tail (the drain caller) — the thread-sync "retry next drain" philosophy.
/// The server is the source of truth; there is no local replica to swap the
/// ticket against.
async fn NowledgeMem::flush_memory_add(
  self : NowledgeMem,
  entry~ : @posoco.MemoryEntry,
) -> Bool {
  let outcome = self.mcp.call_tool(
    "memory_add",
    memory_add_mcp_args(entry, self.config),
    timeout_ms=NMEM_MEMORY_OP_TIMEOUT_MS,
  ) catch {
    err => {
      self.mem.last_error = Some("memory add failed: " + err.to_string())
      return false
    }
  }
  match outcome {
    Err(message) => {
      self.mem.last_error = Some("memory add failed: " + message)
      false
    }
    Ok({ is_error: true, text, }) => {
      self.mem.last_error = Some(
        "memory add failed: \{take_prefix(text, NMEM_TOOL_ERROR_CHARS)}",
      )
      false
    }
    Ok(_) => true
  }
}

///|
/// Flush one queued `Delete` with the `memory_delete` tool (`memory_id` is
/// the server's argument name — the CLI's positional id does not carry
/// over).
async fn NowledgeMem::flush_memory_delete(
  self : NowledgeMem,
  id~ : String,
) -> Bool {
  let fields : Map[String, Json] = { "memory_id": Json::string(id) }
  let outcome = self.mcp.call_tool(
    "memory_delete",
    mcp_args(self.config, fields),
    timeout_ms=NMEM_MEMORY_OP_TIMEOUT_MS,
  ) catch {
    err => {
      self.mem.last_error = Some("memory delete failed: " + err.to_string())
      return false
    }
  }
  match outcome {
    Err(message) => {
      self.mem.last_error = Some("memory delete failed: " + message)
      false
    }
    Ok({ is_error: true, text, }) => {
      self.mem.last_error = Some(
        "memory delete failed: \{take_prefix(text, NMEM_TOOL_ERROR_CHARS)}",
      )
      false
    }
    Ok(_) => true
  }
}

///|
/// Drain the write-after queue once: every op present at entry is attempted
/// exactly once, in order; failures re-enqueue at the tail for the next
/// drain rather than blocking the ops behind them.
pub async fn NowledgeMem::drain_memory_ops(self : NowledgeMem) -> Unit {
  let mut remaining = self.mem.queue.length()
  while remaining > 0 {
    remaining = remaining - 1
    let op = self.mem.queue.remove(0)
    let flushed = match op {
      Add(entry~, ..) => self.flush_memory_add(entry~)
      Delete(id~) => self.flush_memory_delete(id~)
    }
    if !flushed {
      self.mem.queue.push(op)
    }
  }
}
