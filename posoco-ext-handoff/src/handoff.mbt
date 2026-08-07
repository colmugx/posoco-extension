///|
/// `Handoff` checkpoints current project work into `.handoff/` and transfers
/// ownership between Posoco sessions. It deliberately performs no LLM call
/// and no context compaction.
pub(all) struct Handoff {
  cwd : String
  fs : &@workspace.WorkspaceFs
  probe : &HandoffWorkspaceProbe
  collect_work : () -> WorkSnapshot
}

///|
pub fn Handoff::new(
  cwd : String,
  fs : &@workspace.WorkspaceFs,
  probe : &HandoffWorkspaceProbe,
  collect_work : () -> WorkSnapshot,
) -> Handoff {
  { cwd, fs, probe, collect_work }
}

///|
fn Handoff::handoff_dir(self : Handoff) -> String {
  if self.cwd.has_suffix("/") {
    self.cwd + ".handoff"
  } else {
    self.cwd + "/.handoff"
  }
}

///|
fn Handoff::state_path(self : Handoff) -> String {
  self.handoff_dir() + "/state.json"
}

///|
fn Handoff::document_path(self : Handoff) -> String {
  self.handoff_dir() + "/HANDOFF.md"
}

///|
fn fs_failure(error : @workspace.WorkspaceFsError) -> String {
  error.to_string()
}

///|
async fn Handoff::read_state_optional(
  self : Handoff,
) -> Result[HandoffState?, String] {
  let path = self.state_path()
  let present = self.fs.exists(path) catch {
    err => return Err(fs_failure(err))
  }
  if !present {
    return Ok(None)
  }
  let text = self.fs.read_file(path) catch {
    err => return Err(fs_failure(err))
  }
  let json = @json.parse(text) catch {
    _ => return Err(".handoff/state.json is not valid JSON")
  }
  match handoff_state_from_json(json) {
    Ok(state) => Ok(Some(state))
    Err(reason) => Err("invalid .handoff/state.json: " + reason)
  }
}

///|
async fn Handoff::read_state(self : Handoff) -> Result[HandoffState, String] {
  match self.read_state_optional() {
    Ok(Some(state)) => Ok(state)
    Ok(None) => Err("no handoff exists in this project")
    Err(reason) => Err(reason)
  }
}

///|
fn markdown_optional(value : String?) -> String {
  match value {
    Some(text) if text.length() > 0 => text
    _ => "_(unspecified)_"
  }
}

///|
fn markdown_list(values : Array[String]) -> String {
  if values.is_empty() {
    return "- _(none recorded)_\n"
  }
  let mut result = ""
  for value in values {
    result += "- " + value + "\n"
  }
  result
}

///|
fn render_handoff_document(state : HandoffState) -> String {
  let branch = markdown_optional(state.workspace.branch)
  let head = markdown_optional(state.workspace.head)
  let target = markdown_optional(state.target_session_id)
  let rejection = markdown_optional(state.rejection_reason)
  "# Work Handoff\n\n" +
  "> This document is generated deterministically from `.handoff/state.json`.\n" +
  "> Machine state is authoritative; this Markdown file is its human-readable view.\n\n" +
  "## Handoff\n\n" +
  "- ID: `" + state.id + "`\n" +
  "- Generation: `" + state.generation.to_string() + "`\n" +
  "- State: `" + state.status.to_wire() + "`\n" +
  "- Source session: `" + state.source_session_id + "`\n" +
  "- Target session: " + target + "\n" +
  "- Rejection reason: " + rejection + "\n\n" +
  "## Objective\n\n" + markdown_optional(state.work.objective) + "\n\n" +
  "## Current Step\n\n" + markdown_optional(state.work.current_step) + "\n\n" +
  "## Next Action\n\n" + markdown_optional(state.work.next_action) + "\n\n" +
  "## Completed\n\n" + markdown_list(state.work.completed) + "\n" +
  "## Pending\n\n" + markdown_list(state.work.pending) + "\n" +
  "## Validation — Passed\n\n" + markdown_list(state.work.validation_passed) + "\n" +
  "## Validation — Failed\n\n" + markdown_list(state.work.validation_failed) + "\n" +
  "## Validation — Not Run\n\n" + markdown_list(state.work.validation_not_run) + "\n" +
  "## Workspace\n\n" +
  "- Root: `" + state.workspace.root + "`\n" +
  "- Branch: " + branch + "\n" +
  "- HEAD: " + head + "\n" +
  "- Signature: `" + state.workspace.signature + "`\n\n" +
  "### Changed Files\n\n" + markdown_list(state.workspace.changed_files)
}

///|
/// Machine state is authoritative. The derived Markdown is written from the
/// committed state and any derivative-write failure is reported explicitly.
async fn Handoff::persist(self : Handoff, state : HandoffState) -> Result[Unit, String] {
  self.fs.mkdir(self.handoff_dir(), recursive=true) catch {
    err => return Err(fs_failure(err))
  }
  self.fs.write_file_atomic(
    self.state_path(),
    state.stringify() + "\n",
  ) catch {
    err => return Err(fs_failure(err))
  }
  self.fs.write_file_atomic(
    self.document_path(),
    render_handoff_document(state),
  ) catch {
    err =>
      return Err(
        "state.json committed but HANDOFF.md update failed: " + fs_failure(err),
      )
  }
  Ok(())
}

///|
fn array_strings_from_args(fields : Map[String, Json], key : String) -> Array[String] {
  if !fields.contains(key) {
    return []
  }
  match fields[key] {
    Json::Array(values) => {
      let result : Array[String] = []
      for value in values {
        match value {
          Json::String(text) => result.push(text)
          _ => ()
        }
      }
      result
    }
    _ => []
  }
}

///|
fn optional_string_from_args(fields : Map[String, Json], key : String) -> String? {
  if !fields.contains(key) {
    return None
  }
  match fields[key] {
    Json::String(value) if value.length() > 0 => Some(value)
    _ => None
  }
}

///|
fn split_action(raw : String) -> (String?, String?) {
  let trimmed = raw.trim().to_owned()
  if trimmed.length() == 0 {
    return (None, None)
  }
  match trimmed.find(" ") {
    Some(index) => {
      let action = trimmed[0:index].to_owned()
      let rest = trimmed[index + 1:].trim().to_owned()
      (Some(action), if rest.length() > 0 { Some(rest) } else { None })
    }
    None => (Some(trimmed), None)
  }
}

///|
fn command_action(args : Json) -> (String, String?) {
  match args {
    Json::Object(fields) => {
      let explicit_action = optional_string_from_args(fields, "action")
      let positional = optional_string_from_args(fields, "_positional")
      match explicit_action {
        Some(action) => (action, optional_string_from_args(fields, "details"))
        None =>
          match positional {
            Some(raw) =>
              match split_action(raw) {
                (Some(action), rest) => (action, rest)
                _ => ("status", None)
              }
            None => ("status", None)
          }
      }
    }
    Json::String(raw) =>
      match split_action(raw) {
        (Some(action), rest) => (action, rest)
        _ => ("status", None)
      }
    _ => ("status", None)
  }
}

///|
fn work_from_args(args : Json, details : String?) -> WorkSnapshot {
  match args {
    Json::Object(fields) => {
      let objective = match optional_string_from_args(fields, "objective") {
        Some(value) => Some(value)
        None => details
      }
      {
        objective,
        current_step: optional_string_from_args(fields, "current_step"),
        next_action: optional_string_from_args(fields, "next_action"),
        completed: array_strings_from_args(fields, "completed"),
        pending: array_strings_from_args(fields, "pending"),
        validation_passed: array_strings_from_args(fields, "validation_passed"),
        validation_failed: array_strings_from_args(fields, "validation_failed"),
        validation_not_run: array_strings_from_args(fields, "validation_not_run"),
      }
    }
    _ => { ..WorkSnapshot::empty(), objective: details }
  }
}

///|
fn concat_unique(left : Array[String], right : Array[String]) -> Array[String] {
  let result : Array[String] = []
  for value in left {
    if !result.contains(value) {
      result.push(value)
    }
  }
  for value in right {
    if !result.contains(value) {
      result.push(value)
    }
  }
  result
}

///|
fn prefer_optional(overlay : String?, base : String?) -> String? {
  match overlay {
    Some(_) => overlay
    None => base
  }
}

///|
fn merge_work(base : WorkSnapshot, overlay : WorkSnapshot) -> WorkSnapshot {
  {
    objective: prefer_optional(overlay.objective, base.objective),
    current_step: prefer_optional(overlay.current_step, base.current_step),
    next_action: prefer_optional(overlay.next_action, base.next_action),
    completed: concat_unique(base.completed, overlay.completed),
    pending: concat_unique(base.pending, overlay.pending),
    validation_passed: concat_unique(base.validation_passed, overlay.validation_passed),
    validation_failed: concat_unique(base.validation_failed, overlay.validation_failed),
    validation_not_run: concat_unique(base.validation_not_run, overlay.validation_not_run),
  }
}

///|
fn required_session(context : @posoco.CommandInvocationContext) -> Result[String, String] {
  match context.session_id {
    Some(session_id) if session_id.length() > 0 => Ok(session_id)
    _ => Err("handoff ownership commands require a current session id")
  }
}

///|
fn structured_outcome(action : String, state : HandoffState, document_path : String) -> Json {
  Json::object(
    Map::from_array([
      ("action", Json::string(action)),
      ("handoff", state.to_json()),
      ("document_path", Json::string(document_path)),
    ]),
  )
}

///|
async fn Handoff::create_handoff(
  self : Handoff,
  context : @posoco.CommandInvocationContext,
  args : Json,
  details : String?,
) -> @posoco.CommandOutcome {
  let session_id = match required_session(context) {
    Ok(value) => value
    Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
  }
  let previous = match self.read_state_optional() {
    Ok(value) => value
    Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
  }
  let mut generation = 1
  let mut inherited = (self.collect_work)()
  match previous {
    Some(state) => {
      generation = state.generation + 1
      match state.status {
        Offered =>
          return @posoco.CommandOutcome::Failure(
            reason="handoff is already offered; accept, reject, or cancel it first",
          )
        Active =>
          match state.target_session_id {
            Some(owner) if owner == session_id =>
              inherited = merge_work(state.work, inherited)
            _ =>
              return @posoco.CommandOutcome::Failure(
                reason="current session does not own the active handoff",
              )
          }
        Rejected | Cancelled => ()
      }
    }
    None => ()
  }
  let workspace = match self.probe.snapshot(self.cwd) {
    Ok(value) => value
    Err(reason) =>
      return @posoco.CommandOutcome::Failure(
        reason="workspace snapshot failed: " + reason,
      )
  }
  let work = merge_work(inherited, work_from_args(args, details))
  let state : HandoffState = {
    version: 1,
    generation,
    id: "handoff-" + generation.to_string() + "-" + session_id,
    status: Offered,
    source_session_id: session_id,
    target_session_id: None,
    rejected_by_session_id: None,
    rejection_reason: None,
    workspace,
    work,
  }
  match self.persist(state) {
    Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
    Ok(_) =>
      @posoco.CommandOutcome::Success(
        feedback="handoff offered: " + state.id + " (" + self.document_path() + ")",
        structured=Some(
          structured_outcome("handoff_created", state, self.document_path()),
        ),
        ui_hint=Some(@posoco.UiHint::None),
      )
  }
}

///|
async fn Handoff::accept_handoff(
  self : Handoff,
  context : @posoco.CommandInvocationContext,
) -> @posoco.CommandOutcome {
  let session_id = match required_session(context) {
    Ok(value) => value
    Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
  }
  let state = match self.read_state() {
    Ok(value) => value
    Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
  }
  if state.status != Offered {
    return @posoco.CommandOutcome::Failure(
      reason="handoff is not offered (state=" + state.status.to_wire() + ")",
    )
  }
  if state.source_session_id == session_id {
    return @posoco.CommandOutcome::Failure(
      reason="source session cannot accept its own handoff",
    )
  }
  let current = match self.probe.snapshot(self.cwd) {
    Ok(value) => value
    Err(reason) =>
      return @posoco.CommandOutcome::Failure(
        reason="workspace verification failed: " + reason,
      )
  }
  if current.signature != state.workspace.signature {
    return @posoco.CommandOutcome::Failure(
      reason="handoff is stale: workspace changed after it was offered",
    )
  }
  let next : HandoffState = {
    ..state,
    status: Active,
    target_session_id: Some(session_id),
  }
  match self.persist(next) {
    Err(reason) => @posoco.CommandOutcome::Failure(reason~)
    Ok(_) =>
      @posoco.CommandOutcome::Success(
        feedback="handoff accepted: " + next.id,
        structured=Some(
          structured_outcome("handoff_accepted", next, self.document_path()),
        ),
        ui_hint=Some(@posoco.UiHint::None),
      )
  }
}

///|
async fn Handoff::reject_handoff(
  self : Handoff,
  context : @posoco.CommandInvocationContext,
  reason : String?,
) -> @posoco.CommandOutcome {
  let session_id = match required_session(context) {
    Ok(value) => value
    Err(message) => return @posoco.CommandOutcome::Failure(reason=message)
  }
  let state = match self.read_state() {
    Ok(value) => value
    Err(message) => return @posoco.CommandOutcome::Failure(reason=message)
  }
  if state.status != Offered {
    return @posoco.CommandOutcome::Failure(
      reason="only an offered handoff can be rejected",
    )
  }
  if state.source_session_id == session_id {
    return @posoco.CommandOutcome::Failure(
      reason="source session should cancel, not reject, its handoff",
    )
  }
  let next : HandoffState = {
    ..state,
    status: Rejected,
    rejected_by_session_id: Some(session_id),
    rejection_reason: reason,
  }
  match self.persist(next) {
    Err(message) => @posoco.CommandOutcome::Failure(reason=message)
    Ok(_) =>
      @posoco.CommandOutcome::Success(
        feedback="handoff rejected: " + next.id,
        structured=Some(
          structured_outcome("handoff_rejected", next, self.document_path()),
        ),
        ui_hint=Some(@posoco.UiHint::None),
      )
  }
}

///|
async fn Handoff::cancel_handoff(
  self : Handoff,
  context : @posoco.CommandInvocationContext,
) -> @posoco.CommandOutcome {
  let session_id = match required_session(context) {
    Ok(value) => value
    Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
  }
  let state = match self.read_state() {
    Ok(value) => value
    Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
  }
  if state.status != Offered {
    return @posoco.CommandOutcome::Failure(
      reason="only an offered handoff can be cancelled",
    )
  }
  if state.source_session_id != session_id {
    return @posoco.CommandOutcome::Failure(
      reason="only the source session can cancel this handoff",
    )
  }
  let next : HandoffState = { ..state, status: Cancelled }
  match self.persist(next) {
    Err(reason) => @posoco.CommandOutcome::Failure(reason~)
    Ok(_) =>
      @posoco.CommandOutcome::Success(
        feedback="handoff cancelled: " + next.id,
        structured=Some(
          structured_outcome("handoff_cancelled", next, self.document_path()),
        ),
        ui_hint=Some(@posoco.UiHint::None),
      )
  }
}

///|
async fn Handoff::inspect_handoff(self : Handoff) -> @posoco.CommandOutcome {
  let state = match self.read_state() {
    Ok(value) => value
    Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
  }
  let document = self.fs.read_file(self.document_path()) catch {
    _ => render_handoff_document(state)
  }
  @posoco.CommandOutcome::Success(
    feedback=document,
    structured=Some(
      structured_outcome("handoff_inspected", state, self.document_path()),
    ),
    ui_hint=Some(@posoco.UiHint::None),
  )
}

///|
async fn Handoff::status_handoff(self : Handoff) -> @posoco.CommandOutcome {
  match self.read_state_optional() {
    Err(reason) => @posoco.CommandOutcome::Failure(reason~)
    Ok(None) =>
      @posoco.CommandOutcome::Success(
        feedback="no handoff in this project",
        structured=Some(
          Json::object(
            Map::from_array([("status", Json::string("none"))]),
          ),
        ),
        ui_hint=Some(@posoco.UiHint::None),
      )
    Ok(Some(state)) =>
      @posoco.CommandOutcome::Success(
        feedback="handoff " + state.id + ": " + state.status.to_wire(),
        structured=Some(
          structured_outcome("handoff_status", state, self.document_path()),
        ),
        ui_hint=Some(@posoco.UiHint::None),
      )
  }
}

///|
pub impl @posoco.CommandPort for Handoff with fn commands(_self : Handoff) -> Array[
  @posoco.CommandDef,
] {
  [
    @posoco.CommandDef::{
      id: "handoff",
      label: "Handoff",
      description: "Checkpoint current project work and transfer ownership",
      category: "session",
      ctype: @posoco.CommandType::MultiStep,
      params: [
        @posoco.CommandParam::{
          name: "action",
          label: "Action",
          description: "create, inspect, accept, reject, cancel, or status",
          ptype: @posoco.ParamType::Str,
          required: false,
          default: Some(Json::string("status")),
          choices: Some([
            "create",
            "inspect",
            "accept",
            "reject",
            "cancel",
            "status",
          ]),
          positional: true,
        },
        @posoco.CommandParam::{
          name: "details",
          label: "Details",
          description: "Create objective or rejection reason",
          ptype: @posoco.ParamType::Str,
          required: false,
          default: None,
          choices: None,
          positional: true,
        },
      ],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
  ]
}

///|
/// Legacy hosts can inspect/status, but ownership-changing commands require
/// `invoke_with_context` so the source/target session is never guessed.
pub impl @posoco.CommandPort for Handoff with fn invoke(
  self : Handoff,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome {
  self.invoke_with_context(@posoco.CommandInvocationContext::empty(), id, args)
}

///|
pub impl @posoco.CommandPort for Handoff with fn invoke_with_context(
  self : Handoff,
  context : @posoco.CommandInvocationContext,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome {
  if id != "handoff" {
    return @posoco.CommandOutcome::Failure(reason="unknown command: " + id)
  }
  let (action, details) = command_action(args)
  match action {
    "create" => self.create_handoff(context, args, details)
    "inspect" => self.inspect_handoff()
    "accept" => self.accept_handoff(context)
    "reject" => self.reject_handoff(context, details)
    "cancel" => self.cancel_handoff(context)
    "status" => self.status_handoff()
    other =>
      @posoco.CommandOutcome::Failure(
        reason="unknown handoff action: " + other,
      )
  }
}
