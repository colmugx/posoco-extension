///|
/// The local write-after queue (plan D8): `MemoryPort`'s storage slots
/// (`store`/`delete`) are the single write path and they feed this queue —
/// `store` queues an `Add` and hands out a pending ticket synchronously,
/// `delete` drops a pending ticket locally or queues a remote delete; the
/// drain replays every op against the `memory_add` / `memory_delete` MCP
/// calls after the thread lanes. The server is the single source of truth —
/// there is no local replica. The inbound side (`inbound`) lives in
/// `inbound.mbt`, on-demand retrieval (`search`) in `memory_search.mbt`;
/// writes and reads meet only at the server.

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
/// pending ticket plus the staged content and its metadata; `Delete` targets
/// a remote id.
pub(all) enum MemoryOp {
  Add(pending_id~ : String, content~ : String, metadata~ : Map[String, Json])
  Delete(id~ : String)
} derive(Debug)

///|
/// Write-after queue state (D8): `queue` holds the writes the drain replays
/// against the MCP tools. Only the drain coroutine and `MemoryPort`'s
/// synchronous storage slots touch this state; the storage slots only
/// append, so no locking is needed (R7).
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
/// Storage side of `MemoryPort`: queue one memory write and return the
/// pending ticket synchronously — `memory_add`'s single write path. Pure
/// memory work, no IO (D8).
pub impl @posoco.MemoryPort for NowledgeMem with fn store(
  self : NowledgeMem,
  content~ : String,
  metadata~ : Map[String, Json],
) -> String raise @posoco.MemoryError {
  self.mem.next_pending = self.mem.next_pending + 1
  let pending_id = "\{NMEM_PENDING_PREFIX}\{self.mem.next_pending}"
  self.mem.queue.push(Add(pending_id~, content~, metadata~))
  pending_id
}

///|
/// Storage side of `MemoryPort`: queue one memory delete. An empty id is
/// rejected; a pending ticket never reached the server, so dropping its
/// queued `Add` is the whole operation; a real id queues the remote delete
/// for the drain.
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
  content : String,
  metadata : Map[String, Json],
  config : NmemConfig?,
) -> Json {
  let fields : Map[String, Json] = { "content": Json::string(content) }
  match metadata.get("title") {
    Some(Json::String(title)) => fields["title"] = Json::string(title)
    _ => ()
  }
  match metadata.get("unit_type") {
    Some(Json::String(unit_type)) =>
      fields["unit_type"] = Json::string(unit_type)
    _ => ()
  }
  match metadata.get("importance") {
    Some(Json::Number(value, ..)) => fields["importance"] = Json::number(value)
    _ => ()
  }
  match metadata.get("labels") {
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
  content~ : String,
  metadata~ : Map[String, Json],
) -> Bool {
  let outcome = self.mcp.call_tool(
    "memory_add",
    memory_add_mcp_args(content, metadata, self.config),
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
      Add(content~, metadata~, ..) => self.flush_memory_add(content~, metadata~)
      Delete(id~) => self.flush_memory_delete(id~)
    }
    if !flushed {
      self.mem.queue.push(op)
    }
  }
}
