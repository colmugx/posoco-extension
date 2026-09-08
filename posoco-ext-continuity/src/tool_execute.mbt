fn checkpoint_outcome(
  self : ContinuityExtension,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome {
  let session_id = match continuity_current_session(self) {
    Some(id) => id
    None => return continuity_tool_error("session continuity has no active session")
  }
  let run_id = match self.active_run_id {
    Some(id) => id
    None => return continuity_tool_error("session continuity has no active run")
  }
  match self.prepared {
    Some(_) =>
      return continuity_tool_error(
        "a checkpoint is already prepared and awaiting canonical rewrite",
      )
    None => ()
  }
  let fields = match continuity_argument_object(call) {
    Some(value) => value
    None => return continuity_tool_error("session_checkpoint arguments must be an object")
  }
  let candidate_id = match continuity_field_string(fields, "candidate_id") {
    Some(value) => value
    None => return continuity_tool_error("session_checkpoint requires candidate_id")
  }
  let goal = match continuity_field_string(fields, "goal") {
    Some(value) => value
    None => return continuity_tool_error("session_checkpoint requires goal")
  }
  let candidate = match self.candidate {
    Some(value) if value.id == candidate_id &&
      value.session_id == session_id &&
      value.run_id == run_id => value
    Some(_) =>
      return continuity_tool_error(
        "checkpoint candidate is stale or does not match the active invocation",
      )
    None => return continuity_tool_error("no checkpoint candidate is currently active")
  }
  let summary : CheckpointSummary = {
    goal,
    completed: continuity_field_string_array(fields, "completed"),
    decisions: continuity_field_string_array(fields, "decisions"),
    artifacts: continuity_field_string_array(fields, "artifacts"),
    facts: continuity_field_string_array(fields, "facts"),
    open_threads: continuity_field_string_array(fields, "open_threads"),
  }
  if !summary.is_meaningful() {
    return continuity_tool_error(
      "checkpoint summary must include a goal and durable content",
    )
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
  // Safety ordering: exact source messages are archived before any state can
  // authorize their removal from the canonical transcript.
  self.archive.append(session_id, archived)
  self.prepared = Some({ checkpoint_id, candidate, summary })
  // A candidate is single-use. The PreparedCheckpoint owns everything the
  // next before_model boundary needs, so consuming it here also makes a
  // duplicate session_checkpoint call fail deterministically.
  self.candidate = None
  continuity_tool_success(
    "checkpoint \{checkpoint_id} archived and prepared for canonical rewrite",
    Json::object(
      Map::from_array([
        ("checkpoint_id", Json::string(checkpoint_id)),
        (
          "archived_messages",
          Json::number(candidate.source_messages.length().to_double()),
        ),
        ("status", Json::string("prepared")),
      ]),
    ),
  )
}

fn search_outcome(
  self : ContinuityExtension,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome {
  let session_id = match continuity_current_session(self) {
    Some(id) => id
    None => return continuity_tool_error("session continuity has no active session")
  }
  let fields = match continuity_argument_object(call) {
    Some(value) => value
    None => return continuity_tool_error("session_history_search arguments must be an object")
  }
  let query = match continuity_field_string(fields, "query") {
    Some(value) if value != "" => value
    _ => return continuity_tool_error("session_history_search requires a non-empty query")
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
  continuity_tool_success(
    if text.is_empty() { "no archived history matched" } else { text.join("\n") },
    Json::object(Map::from_array([("hits", Json::array(rows))])),
  )
}

fn read_outcome(
  self : ContinuityExtension,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome {
  let session_id = match continuity_current_session(self) {
    Some(id) => id
    None => return continuity_tool_error("session continuity has no active session")
  }
  let fields = match continuity_argument_object(call) {
    Some(value) => value
    None => return continuity_tool_error("session_history_read arguments must be an object")
  }
  let ref = match continuity_field_string(fields, "ref") {
    Some(value) if value != "" => value
    _ => return continuity_tool_error("session_history_read requires ref")
  }
  let cursor = if fields.contains("cursor") {
    match continuity_field_string(fields, "cursor") {
      Some(text) =>
        match continuity_parse_cursor(text) {
          Some(value) => value
          None =>
            return continuity_tool_error(
              "session_history_read cursor must be a non-negative integer string",
            )
        }
      None => return continuity_tool_error("session_history_read cursor must be a string")
    }
  } else {
    0
  }
  match self.archive.read(session_id, ref, cursor, self.config.read_page_chars) {
    None => continuity_tool_error("history reference was not found in the active session")
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
      continuity_tool_success(page.content, structured)
    }
  }
}

fn status_outcome(self : ContinuityExtension) -> @posoco.ToolOutcome {
  let session_id = match continuity_current_session(self) {
    Some(id) => id
    None => return continuity_tool_error("session continuity has no active session")
  }
  let checkpoint_count = match self.checkpoint_counts.get(session_id) {
    Some(value) => value
    None => 0
  }
  let candidate_pending = match self.candidate {
    Some(_) => true
    None => false
  }
  let checkpoint_prepared = match self.prepared {
    Some(_) => true
    None => false
  }
  let structured = Json::object(
    Map::from_array([
      ("session_id", Json::string(session_id)),
      ("checkpoint_count", Json::number(checkpoint_count.to_double())),
      (
        "archived_messages",
        Json::number(self.archive.count(session_id).to_double()),
      ),
      ("candidate_pending", Json::boolean(candidate_pending)),
      ("checkpoint_prepared", Json::boolean(checkpoint_prepared)),
    ]),
  )
  continuity_tool_success(structured.stringify(), structured)
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
    _ => continuity_tool_error("unknown Session Continuity tool: " + name)
  }
}
