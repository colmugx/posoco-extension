///|
/// Timeout for the startup index refresh (`nmem --json m -n 200`).
const NMEM_MEMORY_REFRESH_TIMEOUT_MS : Int = 8000

///|
/// Timeout for one queued write-back (`m add` / `m delete`) during drain.
const NMEM_MEMORY_OP_TIMEOUT_MS : Int = 30000

///|
/// Prefix marking a store ticket whose write-back has not been acknowledged
/// yet (D8): the index entry carries it until the drain swaps in the server
/// id.
const NMEM_PENDING_PREFIX : String = "pending:"

///|
/// How many server memories the startup refresh pulls into the local index.
const NMEM_MEMORY_INDEX_LIMIT : Int = 200

///|
/// Importance applied to entries whose metadata carries no numeric
/// "importance" key (D8 cheap-scoring default).
const NMEM_DEFAULT_IMPORTANCE : Double = 0.5

///|
/// One queued write-back operation (D8 write-after queue). `Add` carries the
/// pending ticket plus the staged entry; `Delete` targets a remote id.
pub(all) enum MemoryOp {
  Add(pending_id~ : String, entry~ : @posoco.MemoryEntry)
  Delete(id~ : String)
} derive(Debug)

///|
/// Local memory state (D8): `index` is the in-memory copy `search` scores
/// synchronously, and `queue` holds the writes the drain replays against the
/// CLI. Only the drain coroutine and the sync MemoryPort slots touch this
/// state; the sync slots only append, so no locking is needed (R7).
pub(all) struct MemoryState {
  index : Array[@posoco.MemoryEntry]
  queue : Array[MemoryOp]
  mut last_error : String?
  mut next_pending : Int
}

///|
pub fn MemoryState::MemoryState() -> MemoryState {
  { index: [], queue: [], last_error: None, next_pending: 0 }
}

///|
/// Store through the local copy: stage the entry in the index under a pending
/// ticket id, queue the `Add` for the drain, and return the ticket
/// synchronously. Pure memory work — no IO can appear in this slot (D8).
pub impl @posoco.MemoryPort for NowledgeMem with fn store(
  self : NowledgeMem,
  entry : @posoco.MemoryEntry,
) -> String raise @posoco.MemoryError {
  self.mem.next_pending = self.mem.next_pending + 1
  let pending_id = "\{NMEM_PENDING_PREFIX}\{self.mem.next_pending}"
  let staged : @posoco.MemoryEntry = { ..entry, id: pending_id }
  self.mem.index.push(staged)
  self.mem.queue.push(Add(pending_id~, entry~))
  pending_id
}

///|
/// Search the local index with the D8 cheap scoring: token overlap (each
/// whitespace-separated query token hit in content or title counts 1) * 2.0
/// + metadata importance (default 0.5) + 1.0 when the whole query string
/// appears. Entries with no token hit and no whole-string hit are not
/// matches; `threshold` filters on the score, the filter's "labels" key
/// (Json array) intersects entry labels, and results come back score-
/// descending up to `top_k`. Synchronous by construction.
pub impl @posoco.MemoryPort for NowledgeMem with fn search(
  self : NowledgeMem,
  query : @posoco.MemoryQuery,
) -> Array[@posoco.MemoryEntry] raise @posoco.MemoryError {
  local_memory_search(self.mem, query)
}

///|
/// Delete through the local copy: an empty id is rejected; a pending ticket
/// never reached the server, so dropping the staged entry (and its queued
/// `Add`) is the whole operation; a real id leaves the index immediately and
/// queues the remote delete for the drain.
pub impl @posoco.MemoryPort for NowledgeMem with fn delete(
  self : NowledgeMem,
  id : String,
) -> Unit raise @posoco.MemoryError {
  if id == "" {
    raise @posoco.MemoryError::Delete("empty id")
  }
  remove_index_entry(self.mem, id)
  if id.has_prefix(NMEM_PENDING_PREFIX) {
    drop_queued_add(self.mem, id)
  } else {
    self.mem.queue.push(Delete(id~))
  }
}

///|
pub extend NowledgeMem with @posoco.MemoryPort::{store, search, delete}

///|
/// Entry title from the metadata convention key, "" when absent.
fn memory_entry_title(entry : @posoco.MemoryEntry) -> String {
  match entry.metadata.get("title") {
    Some(Json::String(title)) => title
    _ => ""
  }
}

///|
/// Entry importance from the metadata convention key, defaulting to
/// NMEM_DEFAULT_IMPORTANCE for absent/non-numeric values.
fn memory_entry_importance(entry : @posoco.MemoryEntry) -> Double {
  match entry.metadata.get("importance") {
    Some(Json::Number(value, ..)) => value
    _ => NMEM_DEFAULT_IMPORTANCE
  }
}

///|
/// Entry labels from the metadata convention key; non-array or non-string
/// items read as no labels.
fn memory_entry_labels(entry : @posoco.MemoryEntry) -> Array[String] {
  match entry.metadata.get("labels") {
    Some(Json::Array(items)) => {
      let labels : Array[String] = []
      for item in items {
        match item {
          Json::String(label) => labels.push(label)
          _ => ()
        }
      }
      labels
    }
    _ => []
  }
}

///|
/// Synchronous local search over a MemoryState (D8 passive read path).
fn local_memory_search(
  state : MemoryState,
  query : @posoco.MemoryQuery,
) -> Array[@posoco.MemoryEntry] {
  let query_text = query.query.to_lower()
  let tokens : Array[String] = []
  for token in query_text.split(" ") {
    let owned = token.to_owned()
    if owned != "" {
      tokens.push(owned)
    }
  }
  let filter_labels : Array[String] = match query.filter.get("labels") {
    Some(Json::Array(items)) => {
      let labels : Array[String] = []
      for item in items {
        match item {
          Json::String(label) => labels.push(label)
          _ => ()
        }
      }
      labels
    }
    _ => []
  }
  // Decorated with the original position: sort_by is unstable, so the index
  // breaks score ties deterministically.
  let scored : Array[(Double, Int, @posoco.MemoryEntry)] = []
  for position, entry in state.index {
    let content = entry.content.to_lower()
    let title = memory_entry_title(entry).to_lower()
    let mut token_hits = 0
    for token in tokens {
      if content.contains(token) || title.contains(token) {
        token_hits = token_hits + 1
      }
    }
    let whole_hit = query_text != "" &&
      (content.contains(query_text) || title.contains(query_text))
    if token_hits == 0 && !whole_hit {
      continue
    }
    if !filter_labels.is_empty() {
      let entry_labels = memory_entry_labels(entry)
      let mut intersects = false
      for label in entry_labels {
        if filter_labels.contains(label) {
          intersects = true
          break
        }
      }
      if !intersects {
        continue
      }
    }
    let whole_bonus = if whole_hit { 1.0 } else { 0.0 }
    let score = token_hits.to_double() * 2.0 +
      memory_entry_importance(entry) +
      whole_bonus
    scored.push((score, position, entry))
  }
  scored.sort_by((a, b) => {
    if a.0 != b.0 {
      if a.0 > b.0 {
        -1
      } else {
        1
      }
    } else if a.1 < b.1 {
      -1
    } else if a.1 > b.1 {
      1
    } else {
      0
    }
  })
  let out : Array[@posoco.MemoryEntry] = []
  for scored_entry in scored {
    if out.length() >= query.top_k {
      break
    }
    let (score, _, entry) = scored_entry
    match query.threshold {
      Some(threshold) =>
        if score >= threshold {
          out.push({ ..entry, score: Some(score) })
        }
      None => out.push({ ..entry, score: Some(score) })
    }
  }
  out
}

///|
/// Remove the entry with `id` from the index, if present.
fn remove_index_entry(state : MemoryState, id : String) -> Unit {
  let mut i = 0
  while i < state.index.length() {
    if state.index[i].id == id {
      ignore(state.index.remove(i))
    } else {
      i = i + 1
    }
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
/// String field of a Json object.
fn json_string_field(data : Json, key : String) -> String? {
  match json_field(data, key) {
    Some(Json::String(value)) => Some(value)
    _ => None
  }
}

///|
/// One item of `nmem --json m` output as a MemoryEntry; `None` when the item
/// carries no usable id (it could never be addressed by delete/update).
fn parse_memory_item(item : Json) -> @posoco.MemoryEntry? {
  guard item is Json::Object(_) else { return None }
  let id = match json_string_field(item, "id") {
    Some(id) => id
    None => return None
  }
  let metadata : Map[String, Json] = Map::from_array([])
  match json_string_field(item, "title") {
    Some(title) => metadata["title"] = Json::string(title)
    None => ()
  }
  match json_string_field(item, "unit_type") {
    Some(unit_type) => metadata["unit_type"] = Json::string(unit_type)
    None => ()
  }
  match json_field(item, "importance") {
    Some(Json::Number(value, ..)) =>
      metadata["importance"] = Json::number(value)
    _ => ()
  }
  match json_field(item, "labels") {
    Some(labels) => if labels is Json::Array(_) { metadata["labels"] = labels }
    None => ()
  }
  let content = match json_string_field(item, "content") {
    Some(content) => content
    None => ""
  }
  Some({ id, content, metadata, score: None })
}

///|
/// Parsed `memories` array of a memory-list CLI payload; `None` for any other
/// shape.
fn parse_memory_list(stdout : String) -> Array[@posoco.MemoryEntry]? {
  let parsed = @json.parse(stdout) catch { _ => return None }
  match json_field(parsed, "memories") {
    Some(Json::Array(items)) => {
      let entries : Array[@posoco.MemoryEntry] = []
      for item in items {
        match parse_memory_item(item) {
          Some(entry) => entries.push(entry)
          None => ()
        }
      }
      Some(entries)
    }
    _ => None
  }
}

///|
/// Replace the local index with the server's current memories
/// (`nmem --json m -n 200`), keeping not-yet-flushed pending entries at the
/// front so a store staged before the refresh stays searchable. Any failure
/// leaves the index untouched and records `last_error`.
pub async fn NowledgeMem::refresh_memory_index(self : NowledgeMem) -> Unit {
  let args = with_ambient_space(
    ["--json", "m", "-n", "\{NMEM_MEMORY_INDEX_LIMIT}"],
    self.config,
  )
  let outcome = NmemRunner::run_cli(
    self.runner,
    args,
    timeout_ms=NMEM_MEMORY_REFRESH_TIMEOUT_MS,
  )
  if outcome.exit != 0 {
    self.mem.last_error = Some(
      "memory index refresh failed (\{outcome.exit}): \{outcome.stderr}",
    )
    return
  }
  match parse_memory_list(outcome.stdout) {
    Some(remote) => {
      let merged : Array[@posoco.MemoryEntry] = []
      for entry in self.mem.index {
        if entry.id.has_prefix(NMEM_PENDING_PREFIX) {
          merged.push(entry)
        }
      }
      for entry in remote {
        merged.push(entry)
      }
      self.mem.index.clear()
      for entry in merged {
        self.mem.index.push(entry)
      }
    }
    None =>
      self.mem.last_error = Some(
        "memory index refresh failed: unparseable memories payload",
      )
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
/// Flush one queued `Add`: run `m add`, and on an acknowledged id swap the
/// pending ticket for the server id in the index. Any failure re-enqueues at
/// the queue tail (the drain caller) and leaves the pending entry searchable
/// — the thread-sync "retry next drain" philosophy.
async fn NowledgeMem::flush_memory_add(
  self : NowledgeMem,
  pending_id~ : String,
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
    Some(real_id) => {
      for i, indexed in self.mem.index {
        if indexed.id == pending_id {
          self.mem.index[i] = { ..indexed, id: real_id }
          break
        }
      }
      true
    }
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
      Add(pending_id~, entry~) => self.flush_memory_add(pending_id~, entry~)
      Delete(id~) => self.flush_memory_delete(id~)
    }
    if !flushed {
      self.mem.queue.push(op)
    }
  }
}
