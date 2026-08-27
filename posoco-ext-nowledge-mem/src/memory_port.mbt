///|
/// Timeout for the one-shot passive working-memory read (`wm read`) —
/// passive retrieval sits on the model-call path, so it fails faster than
/// the tool budget.
const NMEM_PASSIVE_READ_TIMEOUT_MS : Int = 5000

///|
/// Timeout for one queued write-back (`m add` / `m delete`) during drain.
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
/// against the CLI. Only the drain coroutine and the sync MemoryPort slots
/// touch this state; the sync slots only append, so no locking is needed
/// (R7).
pub(all) struct MemoryState {
  queue : Array[MemoryOp]
  mut last_error : String?
  mut next_pending : Int
}

///|
pub fn MemoryState::MemoryState() -> MemoryState {
  { queue: [], last_error: None, next_pending: 0 }
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
/// working memory — `nmem --json wm read`, the same surface the
/// `read_working_memory` tool exposes — and core's MemoryRetrievalHook
/// renders it as the "Any Memory About This Work" section that persists
/// for the session (a later hit replaces it in place). Every later call
/// returns `[]` without touching the CLI: recall past the startup read is
/// the model's job, via the `memory_search` tool. The gate is spent before
/// the attempt, so a failure also exhausts it; raising is the intended
/// observability path — core's `search_all` catches the raise and reports
/// it as a secondary-failure observer event. A resumed process starts with
/// a fresh gate, so its first call re-reads and core swaps the old section
/// for the new content.
pub impl @posoco.MemoryPort for NowledgeMem with fn search(
  self : NowledgeMem,
  _query : @posoco.MemoryQuery,
) -> Array[@posoco.MemoryEntry] raise @posoco.MemoryError {
  if self.passive_read_done {
    return []
  }
  self.passive_read_done = true
  let outcome : CliOutcome? = try
    NmemRunner::run_cli(
      self.runner,
      with_ambient_space(["--json", "wm", "read"], self.config),
      timeout_ms=NMEM_PASSIVE_READ_TIMEOUT_MS,
    )
  catch {
    _ => None
  } noraise {
    value => Some(value)
  }
  let outcome = match outcome {
    None => {
      self.mem.last_error = Some("working memory read failed: CLI run raised")
      raise @posoco.MemoryError::Search("working memory read raised")
    }
    Some(outcome) => outcome
  }
  if outcome.exit != 0 {
    self.mem.last_error = Some(
      "working memory read failed (\{outcome.exit}): \{outcome.stderr}",
    )
    raise @posoco.MemoryError::Search("nmem exited with code \{outcome.exit}")
  }
  match clean_json_object(outcome.stdout) {
    None =>
      raise @posoco.MemoryError::Search("unparseable working-memory payload")
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
/// String field of a Json object.
fn json_string_field(data : Json, key : String) -> String? {
  match json_field(data, key) {
    Some(Json::String(value)) => Some(value)
    _ => None
  }
}

///|
/// Append "--space <space>" when a config with a space is set (upstream
/// withAmbientNmemArgs scoped-command behavior; callers pass only m/t
/// command bases).
fn with_ambient_space(
  base : Array[String],
  config : NmemConfig?,
) -> Array[String] {
  let args : Array[String] = []
  for item in base {
    args.push(item)
  }
  match config {
    Some({ space: Some(space), .. }) => {
      args.push("--space")
      args.push(space)
    }
    _ => ()
  }
  args
}

///|
/// argv for one queued `m add`, mapping the metadata convention keys to CLI
/// flags: title → -t, unit_type → --unit-type, importance → -i, labels →
/// repeatable -l.
fn memory_add_args(entry : @posoco.MemoryEntry) -> Array[String] {
  let args : Array[String] = ["--json", "m", "add", entry.content]
  match entry.metadata.get("title") {
    Some(Json::String(title)) => {
      args.push("-t")
      args.push(title)
    }
    _ => ()
  }
  match entry.metadata.get("unit_type") {
    Some(Json::String(unit_type)) => {
      args.push("--unit-type")
      args.push(unit_type)
    }
    _ => ()
  }
  match entry.metadata.get("importance") {
    Some(Json::Number(value, ..)) => {
      args.push("-i")
      args.push("\{value}")
    }
    _ => ()
  }
  match entry.metadata.get("labels") {
    Some(Json::Array(items)) =>
      for item in items {
        match item {
          Json::String(label) => {
            args.push("-l")
            args.push(label)
          }
          _ => ()
        }
      }
    _ => ()
  }
  args
}

///|
/// Server id from a `m add` payload: `{id: ...}` or `{memory: {id: ...}}`.
fn parse_memory_add_id(stdout : String) -> String? {
  let parsed = @json.parse(stdout) catch { _ => return None }
  match json_string_field(parsed, "id") {
    Some(id) => Some(id)
    None =>
      match json_field(parsed, "memory") {
        Some(memory) => json_string_field(memory, "id")
        None => None
      }
  }
}

///|
/// Flush one queued `Add`: run `m add` and treat an acknowledged id in the
/// response as success (no id = failure). Any failure re-enqueues at the
/// queue tail (the drain caller) — the thread-sync "retry next drain"
/// philosophy. The server is the source of truth; there is no local replica
/// to swap the ticket against.
async fn NowledgeMem::flush_memory_add(
  self : NowledgeMem,
  entry~ : @posoco.MemoryEntry,
) -> Bool {
  let args = with_ambient_space(memory_add_args(entry), self.config)
  let outcome = NmemRunner::run_cli(
    self.runner,
    args,
    timeout_ms=NMEM_MEMORY_OP_TIMEOUT_MS,
  )
  if outcome.exit != 0 {
    self.mem.last_error = Some(
      "memory add failed (\{outcome.exit}): \{outcome.stderr}",
    )
    return false
  }
  match parse_memory_add_id(outcome.stdout) {
    Some(_id) => true
    None => {
      self.mem.last_error = Some("memory add response carried no id")
      false
    }
  }
}

///|
/// Flush one queued `Delete` with `m delete <id> -f` (the -f flag is
/// mandatory — without it the CLI blocks interactively).
async fn NowledgeMem::flush_memory_delete(
  self : NowledgeMem,
  id~ : String,
) -> Bool {
  let args = with_ambient_space(
    ["--json", "m", "delete", id, "-f"],
    self.config,
  )
  let outcome = NmemRunner::run_cli(
    self.runner,
    args,
    timeout_ms=NMEM_MEMORY_OP_TIMEOUT_MS,
  )
  if outcome.exit != 0 {
    self.mem.last_error = Some(
      "memory delete failed (\{outcome.exit}): \{outcome.stderr}",
    )
    return false
  }
  true
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
