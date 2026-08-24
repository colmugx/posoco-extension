///|
/// `Handoff` writes a deterministic project-local work continuation document.
/// It does not compact context, inspect session state, or transfer ownership.
pub(all) struct Handoff {
  cwd : String
  store : &HandoffStore
  probe : &HandoffWorkspaceProbe
  work_sources : Array[&HandoffWorkSource]
}

///|
pub fn Handoff::Handoff(
  cwd~ : String,
  store~ : &HandoffStore,
  probe~ : &HandoffWorkspaceProbe,
  work_sources~ : Array[&HandoffWorkSource],
) -> Handoff {
  { cwd, store, probe, work_sources }
}

///|
fn handoff_dir(root : String) -> String {
  if root.has_suffix("/") {
    root + ".handoff"
  } else {
    root + "/.handoff"
  }
}

///|
fn document_path(root : String) -> String {
  handoff_dir(root) + "/HANDOFF.md"
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
fn render_workspace_changes(values : Array[WorkspaceChange]) -> String {
  if values.is_empty() {
    return "- _(clean workspace)_\n"
  }
  let mut result = ""
  for value in values {
    result += "- `" + value.path + "` — " + value.status + "\n"
  }
  result
}

///|
/// Stable Markdown projection. Conversation history intentionally does not
/// appear here; Posoco's message tree owns that history. This file only records
/// the present work continuation point.
pub fn render_handoff_document(
  work : WorkSnapshot,
  workspace : WorkspaceSnapshot,
) -> String {
  "# Handoff\n\n" +
  "## Objective\n\n" +
  markdown_optional(work.objective) +
  "\n\n" +
  "## Done When\n\n" +
  markdown_list(work.done_when) +
  "\n" +
  "## Constraints\n\n" +
  markdown_list(work.constraints) +
  "\n" +
  "## Completed\n\n" +
  markdown_list(work.completed) +
  "\n" +
  "## Current Work\n\n" +
  markdown_optional(work.current_work) +
  "\n\n" +
  "## Decisions\n\n" +
  markdown_list(work.decisions) +
  "\n" +
  "## Blockers\n\n" +
  markdown_list(work.blockers) +
  "\n" +
  "## Workspace\n\n" +
  "- Root: `" +
  workspace.root +
  "`\n" +
  "- Branch: " +
  markdown_optional(workspace.branch) +
  "\n" +
  "- HEAD: " +
  markdown_optional(workspace.head) +
  "\n\n" +
  "### Changes\n\n" +
  render_workspace_changes(workspace.changes) +
  "\n" +
  "## Validation\n\n" +
  "### Passed\n\n" +
  markdown_list(work.validation_passed) +
  "\n" +
  "### Failed\n\n" +
  markdown_list(work.validation_failed) +
  "\n" +
  "### Not Run\n\n" +
  markdown_list(work.validation_not_run) +
  "\n" +
  "## Next Action\n\n" +
  markdown_optional(work.next_action) +
  "\n\n" +
  "## Queue\n\n" +
  markdown_list(work.queue) +
  "\n" +
  "## Notes\n\n" +
  markdown_list(work.notes)
}

///|
fn array_strings_from_args(
  fields : Map[String, Json],
  key : String,
) -> Array[String] {
  match fields.get(key) {
    Some(Json::Array(values)) => {
      let result : Array[String] = []
      for value in values {
        match value {
          Json::String(text) if text.length() > 0 => result.push(text)
          _ => ()
        }
      }
      result
    }
    _ => []
  }
}

///|
fn optional_string_from_args(
  fields : Map[String, Json],
  key : String,
) -> String? {
  match fields.get(key) {
    Some(Json::String(value)) if value.length() > 0 => Some(value)
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
    Json::Object(fields) =>
      match optional_string_from_args(fields, "action") {
        Some(action) => (action, optional_string_from_args(fields, "details"))
        None => ("create", optional_string_from_args(fields, "details"))
      }
    Json::String(raw) =>
      match split_action(raw) {
        (Some(action), rest) => (action, rest)
        _ => ("create", None)
      }
    _ => ("create", None)
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
        done_when: array_strings_from_args(fields, "done_when"),
        constraints: array_strings_from_args(fields, "constraints"),
        completed: array_strings_from_args(fields, "completed"),
        current_work: optional_string_from_args(fields, "current_work"),
        decisions: array_strings_from_args(fields, "decisions"),
        blockers: array_strings_from_args(fields, "blockers"),
        next_action: optional_string_from_args(fields, "next_action"),
        queue: array_strings_from_args(fields, "queue"),
        notes: array_strings_from_args(fields, "notes"),
        validation_passed: array_strings_from_args(fields, "validation_passed"),
        validation_failed: array_strings_from_args(fields, "validation_failed"),
        validation_not_run: array_strings_from_args(
          fields, "validation_not_run",
        ),
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
/// Merge is deterministic and intentionally asymmetric. Later sources override
/// singular fields and append unique list facts. Command arguments are merged
/// last, so an explicit `/handoff create` value wins over configured sources.
pub fn merge_work(base : WorkSnapshot, overlay : WorkSnapshot) -> WorkSnapshot {
  {
    objective: prefer_optional(overlay.objective, base.objective),
    done_when: concat_unique(base.done_when, overlay.done_when),
    constraints: concat_unique(base.constraints, overlay.constraints),
    completed: concat_unique(base.completed, overlay.completed),
    current_work: prefer_optional(overlay.current_work, base.current_work),
    decisions: concat_unique(base.decisions, overlay.decisions),
    blockers: concat_unique(base.blockers, overlay.blockers),
    next_action: prefer_optional(overlay.next_action, base.next_action),
    queue: concat_unique(base.queue, overlay.queue),
    notes: concat_unique(base.notes, overlay.notes),
    validation_passed: concat_unique(
      base.validation_passed,
      overlay.validation_passed,
    ),
    validation_failed: concat_unique(
      base.validation_failed,
      overlay.validation_failed,
    ),
    validation_not_run: concat_unique(
      base.validation_not_run,
      overlay.validation_not_run,
    ),
  }
}

///|
fn Handoff::collect_work(self : Handoff) -> WorkSnapshot {
  let mut work = WorkSnapshot::empty()
  for source in self.work_sources {
    work = merge_work(work, source.handoff_work())
  }
  work
}

///|
fn validate_work(work : WorkSnapshot) -> String? {
  match work.objective {
    None => return Some("handoff requires an objective")
    Some(value) if value.length() == 0 =>
      return Some("handoff requires an objective")
    _ => ()
  }
  match work.current_work {
    None => return Some("handoff requires current_work")
    Some(value) if value.length() == 0 =>
      return Some("handoff requires current_work")
    _ => ()
  }
  match work.next_action {
    None => return Some("handoff requires exactly one next_action")
    Some(value) if value.length() == 0 =>
      return Some("handoff requires exactly one next_action")
    _ => ()
  }
  None
}

///|
fn structured_outcome(action : String, path : String) -> Json {
  Json::object(
    Map::from_array([
      ("action", Json::string(action)),
      ("document_path", Json::string(path)),
    ]),
  )
}

///|
fn Handoff::probe_workspace(
  self : Handoff,
) -> Result[WorkspaceSnapshot, String] {
  match self.probe.snapshot(self.cwd) {
    Err(reason) => Err("workspace snapshot failed: " + reason)
    Ok(workspace) if workspace.root.length() == 0 =>
      Err("workspace snapshot failed: root is empty")
    Ok(workspace) => Ok(workspace)
  }
}

///|
async fn Handoff::create_handoff(
  self : Handoff,
  args : Json,
  details : String?,
) -> @posoco.CommandOutcome noraise {
  let work = merge_work(self.collect_work(), work_from_args(args, details))
  match validate_work(work) {
    Some(reason) => return @posoco.CommandOutcome::Failure(reason~)
    None => ()
  }
  let workspace = match self.probe_workspace() {
    Ok(value) => value
    Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
  }
  let dir = handoff_dir(workspace.root)
  let path = document_path(workspace.root)
  let document = render_handoff_document(work, workspace)
  let ensure_result = self.store.ensure_dir(dir) catch {
    _ =>
      return @posoco.CommandOutcome::Failure(
        reason="handoff store ensure_dir raised unexpectedly",
      )
  }
  match ensure_result {
    Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
    Ok(_) => ()
  }
  let write_result = self.store.write_atomic(path, document) catch {
    _ =>
      return @posoco.CommandOutcome::Failure(
        reason="handoff store write_atomic raised unexpectedly",
      )
  }
  match write_result {
    Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
    Ok(_) => ()
  }
  @posoco.CommandOutcome::Success(
    feedback="handoff written: " + path,
    structured=Some(structured_outcome("handoff_created", path)),
    ui_hint=Some(@posoco.UiHint::None),
  )
}

///|
async fn Handoff::inspect_handoff(
  self : Handoff,
) -> @posoco.CommandOutcome noraise {
  let workspace = match self.probe_workspace() {
    Ok(value) => value
    Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
  }
  let path = document_path(workspace.root)
  let exists_result = self.store.exists(path) catch {
    _ =>
      return @posoco.CommandOutcome::Failure(
        reason="handoff store exists raised unexpectedly",
      )
  }
  let present = match exists_result {
    Ok(value) => value
    Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
  }
  if !present {
    return @posoco.CommandOutcome::Failure(
      reason="no .handoff/HANDOFF.md exists in this project",
    )
  }
  let read_result = self.store.read(path) catch {
    _ =>
      return @posoco.CommandOutcome::Failure(
        reason="handoff store read raised unexpectedly",
      )
  }
  let document = match read_result {
    Ok(value) => value
    Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
  }
  @posoco.CommandOutcome::Success(
    feedback=document,
    structured=Some(structured_outcome("handoff_inspected", path)),
    ui_hint=Some(@posoco.UiHint::None),
  )
}

///|
pub impl @posoco.CommandPort for Handoff with fn commands(_self : Handoff) -> Array[
  @posoco.CommandDef,
] {
  [
    @posoco.CommandDef::{
      id: "handoff",
      label: "Handoff",
      description: "Write or inspect the current project work handoff",
      category: "workflow",
      ctype: @posoco.CommandType::MultiStep,
      params: [
        @posoco.CommandParam::{
          name: "action",
          label: "Action",
          description: "create or inspect",
          ptype: @posoco.ParamType::Str,
          required: false,
          default: Some(Json::string("create")),
          choices: Some(["create", "inspect"]),
          positional: true,
        },
        @posoco.CommandParam::{
          name: "details",
          label: "Objective",
          description: "Objective used by create when no structured objective is supplied",
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
pub impl @posoco.CommandPort for Handoff with fn invoke(
  self : Handoff,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome {
  if id != "handoff" {
    return @posoco.CommandOutcome::Failure(reason="unknown command: " + id)
  }
  let (action, details) = command_action(args)
  match action {
    "create" => self.create_handoff(args, details)
    "inspect" => self.inspect_handoff()
    other =>
      @posoco.CommandOutcome::Failure(
        reason="unknown handoff action: " +
          other +
          " (expected create or inspect)",
      )
  }
}
