fn string_property(description : String) -> Json {
  Json::object(
    Map::from_array([
      ("type", Json::string("string")),
      ("description", Json::string(description)),
    ]),
  )
}

fn string_array_property(description : String) -> Json {
  Json::object(
    Map::from_array([
      ("type", Json::string("array")),
      ("description", Json::string(description)),
      (
        "items",
        Json::object(Map::from_array([("type", Json::string("string"))])),
      ),
    ]),
  )
}

fn object_schema(
  properties : Map[String, Json],
  required : Array[String],
) -> Json {
  Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      ("properties", Json::object(properties)),
      ("required", Json::array(required.map(fn(v) { Json::string(v) }))),
    ]),
  )
}

fn continuity_tool(
  name : String,
  description : String,
  input_schema : Json,
) -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked(name),
    description,
    input_schema,
    owner: @posoco.OwnerId::unchecked("posoco_ext_continuity"),
    policy: @posoco.ExecutionPolicy::Parallel,
    provenance: Some("posoco_ext_continuity"),
  }
}

fn checkpoint_schema() -> Json {
  object_schema(
    Map::from_array([
      (
        "candidate_id",
        string_property("Opaque candidate id supplied by Session Continuity"),
      ),
      ("goal", string_property("Goal of the archived historical segment")),
      (
        "completed",
        string_array_property("Completed work worth carrying forward"),
      ),
      (
        "decisions",
        string_array_property("Important decisions and rationale"),
      ),
      (
        "artifacts",
        string_array_property("Relevant files, symbols, commands or artifacts"),
      ),
      (
        "facts",
        string_array_property("Exact facts, identifiers or values worth preserving"),
      ),
      (
        "open_threads",
        string_array_property("Unresolved work that remains relevant"),
      ),
    ]),
    ["candidate_id", "goal"],
  )
}

fn search_schema() -> Json {
  object_schema(
    Map::from_array([
      ("query", string_property("Exact historical text or lexical search query")),
    ]),
    ["query"],
  )
}

fn read_schema() -> Json {
  object_schema(
    Map::from_array([
      ("ref", string_property("History reference returned by session_history_search")),
      (
        "cursor",
        string_property("Optional non-negative character cursor; defaults to 0"),
      ),
    ]),
    ["ref"],
  )
}

fn status_schema() -> Json {
  object_schema(Map::from_array([]), [])
}

///|
pub impl @posoco.ToolProvider for ContinuityExtension with fn list_tools(
  _self : ContinuityExtension,
) -> Array[@posoco.ToolDef] {
  [
    continuity_tool(
      "session_checkpoint",
      "Archive a system-selected settled history segment and prepare its structured checkpoint",
      checkpoint_schema(),
    ),
    continuity_tool(
      "session_history_search",
      "Search exact archived history for the current session",
      search_schema(),
    ),
    continuity_tool(
      "session_history_read",
      "Read a bounded page from one archived history entry",
      read_schema(),
    ),
    continuity_tool(
      "session_continuity_status",
      "Report Session Continuity state for the current session",
      status_schema(),
    ),
  ]
}

fn argument_object(call : @posoco.ToolCall) -> Map[String, Json]? {
  match call.arguments {
    Json::Object(fields) => Some(fields)
    _ => None
  }
}

fn field_string(fields : Map[String, Json], name : String) -> String? {
  if !fields.contains(name) { return None }
  match fields[name] {
    Json::String(value) => Some(value)
    _ => None
  }
}

fn field_string_array(fields : Map[String, Json], name : String) -> Array[String] {
  if !fields.contains(name) { return [] }
  match fields[name] {
    Json::Array(values) => {
      let out : Array[String] = []
      for value in values {
        match value {
          Json::String(text) => out.push(text)
          _ => ()
        }
      }
      out
    }
    _ => []
  }
}

fn parse_cursor(text : String) -> Int? {
  if text == "" { return Some(0) }
  let mut value = 0
  for ch in text {
    if ch < '0' || ch > '9' { return None }
    value = value * 10 + (ch.to_int() - '0'.to_int())
  }
  Some(value)
}

fn tool_error(message : String) -> @posoco.ToolOutcome {
  @posoco.ToolOutcome::ToolReportedError(content=message, structured=None)
}

fn tool_success(content : String, structured : Json) -> @posoco.ToolOutcome {
  @posoco.ToolOutcome::Success(content~, structured=Some(structured))
}

fn current_session(self : ContinuityExtension) -> String? {
  if !self.turn_active { return None }
  self.active_session_id
}

fn checkpoint_outcome(
  self : ContinuityExtension,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome {
  let session_id = match current_session(self) {
    Some(id) => id
    None => return tool_error("session continuity has no active session")
  }
  let fields = match argument_object(call) {
    Some(value) => value
    None => return tool_error("session_checkpoint arguments must be an object")
  }
  let candidate_id = match field_string(fields, "candidate_id") {
    Some(value) => value
    None => return tool_error("session_checkpoint requires candidate_id")
  }
  let goal = match field_string(fields, "goal") {
    Some(value) => value
    None => return tool_error("session_checkpoint requires goal")
  }
  let candidate = match self.candidate {
    Some(value) if value.id == candidate_id && value.session_id == session_id => value
    Some(_) => return tool_error("checkpoint candidate is stale or does not match the active session")
    None => return tool_error("no checkpoint candidate is currently active")
  }
  let summary : CheckpointSummary = {
    goal,
    completed: field_string_array(fields, "completed"),
    decisions: field_string_array(fields, "decisions"),
    artifacts: field_string_array(fields, "artifacts"),
    facts: field_string_array(fields, "facts"),
    open_threads: field_string_array(fields, "open_threads"),
  }
  if !summary.is_meaningful() {
    return tool_error("checkpoint summary must include a goal and durable content")
  }
  self.checkpoint_seq = self.checkpoint_seq + 1
  let checkpoint_id = "cp_\{self.checkpoint_seq}"
  let archived : Array[ArchivedMessage] = []
  for index, message in candidate.source_messages {
    archived.push({
      id: checkpoint_id + "_h_\{index}",
      checkpoint_id,
      ordinal: index,
      message,
    })
  }
  // Safety ordering: archive first, then mark the checkpoint prepared. The
  // Hook will only remove the canonical source range on the next model
  // boundary if that range still matches exactly.
  self.archive.append(session_id, archived)
  self.prepared = Some({ checkpoint_id, candidate, summary })
  let prior_count = match self.checkpoint_counts.get(session_id) {
    Some(value) => value
    None => 0
  }
  self.checkpoint_counts[session_id] = prior_count + 1
  let structured = Json::object(
    Map::from_array([
      ("checkpoint_id", Json::string(checkpoint_id)),
      ("archived_messages", Json::number(candidate.source_messages.length().to_double())),
      ("status", Json::string("prepared")),
    ]),
  )
  tool_success(
    "checkpoint \{checkpoint_id} archived and prepared for canonical rewrite",
    structured,
  )
}

fn search_outcome(
  self : ContinuityExtension,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome {
  let session_id = match current_session(self) {
    Some(id) => id
    None => return tool_error("session continuity has no active session")
  }
  let fields = match argument_object(call) {
    Some(value) => value
    None => return tool_error("session_history_search arguments must be an object")
  }
  let query = match field_string(fields, "query") {
    Some(value) if value != "" => value
    _ => return tool_error("session_history_search requires a non-empty query")
  }
  let hits = self.archive.search(session_id, query, self.config.search_limit)
  let rows : Array[Json] = []
  let text : Array[String] = []
  for hit in hits {
    rows.push(
      Json::object(
        Map::from_array([
          ("ref", Json::string(hit.ref)),
          ("checkpoint_id", Json::string(hit.checkpoint_id)),
          ("preview", Json::string(hit.preview)),
        ]),
      ),
    )
    text.push("\{hit.ref}: \{hit.preview}")
  }
  tool_success(
    if text.is_empty() { "no archived history matched" } else { text.join("\n") },
    Json::object(Map::from_array([("hits", Json::array(rows))])),
  )
}

fn read_outcome(
  self : ContinuityExtension,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome {
  let session_id = match current_session(self) {
    Some(id) => id
    None => return tool_error("session continuity has no active session")
  }
  let fields = match argument_object(call) {
    Some(value) => value
    None => return tool_error("session_history_read arguments must be an object")
  }
  let ref = match field_string(fields, "ref") {
    Some(value) if value != "" => value
    _ => return tool_error("session_history_read requires ref")
  }
  let cursor = if fields.contains("cursor") {
    match field_string(fields, "cursor") {
      Some(text) =>
        match parse_cursor(text) {
          Some(value) => value
          None => return tool_error("session_history_read cursor must be a non-negative integer string")
        }
      None => return tool_error("session_history_read cursor must be a string")
    }
  } else {
    0
  }
  match self.archive.read(session_id, ref, cursor, self.config.read_page_chars) {
    None => tool_error("history reference was not found in the active session")
    Some(page) => {
      let structured = Json::object(
        Map::from_array([
          ("ref", Json::string(page.ref)),
          ("content", Json::string(page.content)),
          ("done", Json::boolean(page.done)),
          (
            "next_cursor",
            match page.next_cursor {
              Some(value) => Json::string(value.to_string())
              None => Json::null()
            },
          ),
        ]),
      )
      tool_success(page.content, structured)
    }
  }
}

fn status_outcome(self : ContinuityExtension) -> @posoco.ToolOutcome {
  let session_id = match current_session(self) {
    Some(id) => id
    None => return tool_error("session continuity has no active session")
  }
  let checkpoint_count = match self.checkpoint_counts.get(session_id) {
    Some(value) => value
    None => 0
  }
  let structured = Json::object(
    Map::from_array([
      ("session_id", Json::string(session_id)),
      ("checkpoint_count", Json::number(checkpoint_count.to_double())),
      (
        "archived_messages",
        Json::number(self.archive.count(session_id).to_double()),
      ),
      ("candidate_pending", Json::boolean(self.candidate is Some(_))),
      ("checkpoint_prepared", Json::boolean(self.prepared is Some(_))),
    ]),
  )
  tool_success(structured.stringify(), structured)
}

///|
pub impl @posoco.ToolProvider for ContinuityExtension with fn execute(
  self : ContinuityExtension,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  match name {
    "session_checkpoint" => checkpoint_outcome(self, call)
    "session_history_search" => search_outcome(self, call)
    "session_history_read" => read_outcome(self, call)
    "session_continuity_status" => status_outcome(self)
    _ => tool_error("unknown Session Continuity tool: " + name)
  }
}
