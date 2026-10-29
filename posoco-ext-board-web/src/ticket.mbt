///|
/// Host ticket frames. They stay outside the Board task/attempt wire contract.
priv enum TicketFrame {
  TicketSnapshot(TicketState)
  TicketOutcome(Bool, String?, TicketState?)
}

///|
fn ticket_state_from_json(value : Json) -> TicketState {
  let fields = match value {
    Object(fields) => fields
    _ => return TicketState::empty()
  }
  let project = match fields.get("project") {
    Some(String(value)) => value
    _ => ""
  }
  let team_mcp = match fields.get("team_mcp") {
    Some(Object(mcp)) => {
      let out = default_team_mcp()
      for role in ["po", "sm", "rd", "set", "te"] {
        match mcp.get(role) {
          Some(Object(item)) => {
            let enabled = match item.get("enabled") {
              Some(Json::True) => true
              Some(Json::False) => false
              _ => false
            }
            let all = match item.get("all") {
              Some(Json::True) => true
              Some(Json::False) => false
              _ => true
            }
            let servers : Array[String] = []
            let tools : Array[String] = []
            match item.get("tools") {
              Some(Array(items)) =>
                for value in items {
                  match value {
                    String(name) if name != "" && !tools.contains(name) =>
                      tools.push(name)
                    _ => ()
                  }
                }
              _ => ()
            }
            match item.get("servers") {
              Some(Array(items)) =>
                for value in items {
                  match value {
                    String(name) if name != "" && !servers.contains(name) =>
                      servers.push(name)
                    _ => ()
                  }
                }
              _ => ()
            }
            out[role] = { enabled, all, servers, tools }
          }
          _ => ()
        }
      }
      out
    }
    _ => default_team_mcp()
  }
  let team_skills = match fields.get("team_skills") {
    Some(Object(skills)) => {
      let out = default_team_skills()
      for role in ["po", "sm", "rd", "set", "te"] {
        match skills.get(role) {
          Some(Object(item)) => {
            let enabled = match item.get("enabled") {
              Some(Json::True) => true
              Some(Json::False) => false
              _ => false
            }
            let all = match item.get("all") {
              Some(Json::True) => true
              Some(Json::False) => false
              _ => true
            }
            let names : Array[String] = []
            match item.get("skills") {
              Some(Array(items)) =>
                for value in items {
                  match value {
                    String(name) if name != "" && !names.contains(name) =>
                      names.push(name)
                    _ => ()
                  }
                }
              _ => ()
            }
            out[role] = { enabled, all, skills: names }
          }
          _ => ()
        }
      }
      out
    }
    _ => default_team_skills()
  }
  let team = match fields.get("team") {
    Some(Object(team)) => {
      let name = key => {
        match team.get(key) {
          Some(String(value)) if value.trim() != "" => value
          _ => ""
        }
      }
      let defaults = TeamNames::defaults()
      Some({
        po: if name("po") != "" {
          name("po")
        } else if name("refiner") != "" {
          name("refiner")
        } else {
          defaults.po
        },
        sm: if name("sm") == "" { defaults.sm } else { name("sm") },
        rd: if name("rd") == "" { defaults.rd } else { name("rd") },
        set: if name("set") == "" { defaults.set } else { name("set") },
        te: if name("te") == "" { defaults.te } else { name("te") },
        mcp: team_mcp,
        skills: team_skills,
      })
    }
    _ => None
  }
  let mcp_servers = match fields.get("mcp_servers") {
    Some(Object(catalog)) =>
      match catalog.get("servers") {
        Some(Array(items)) =>
          items.filter_map(item => {
            match item {
              Object(server) => {
                let name = match server.get("name") {
                  Some(String(value)) if value != "" => value
                  _ => ""
                }
                if name == "" {
                  return None
                }
                let connected = match server.get("connected") {
                  Some(Json::True) => true
                  Some(Json::False) => false
                  _ => false
                }
                let tools : Array[String] = []
                match server.get("tools") {
                  Some(Array(items)) =>
                    for tool in items {
                      match tool {
                        String(value) => tools.push(value)
                        _ => ()
                      }
                    }
                  _ => ()
                }
                Some({ name, connected, tools })
              }
              _ => None
            }
          })
        _ => []
      }
    _ => []
  }
  let skills = match fields.get("skills") {
    Some(Array(items)) =>
      items.filter_map(item => {
        match item {
          Object(skill) => {
            let name = match skill.get("name") {
              Some(String(value)) if value != "" => value
              _ => ""
            }
            if name == "" {
              return None
            }
            let description = match skill.get("description") {
              Some(String(value)) => value
              _ => ""
            }
            Some({ name, description })
          }
          _ => None
        }
      })
    _ => []
  }
  let profile = match fields.get("work_profile") {
    Some(Object(profile)) =>
      match profile.get("id") {
        Some(String("document")) => { id: "document", label: "Document" }
        Some(String("analysis")) => { id: "analysis", label: "Analysis" }
        _ => WorkProfile::software()
      }
    _ => WorkProfile::software()
  }
  let questions = match fields.get("questions") {
    Some(Array(items)) => items.filter_map(decode_ticket_question)
    _ => []
  }
  let runs = match fields.get("runs") {
    Some(Array(items)) => items.filter_map(decode_ticket_run)
    _ => []
  }
  // Worker progress: absent reads as empty and every malformed entry is
  // dropped on its own, so one bad update never hides the rest of the inbox.
  let progress = match fields.get("progress") {
    Some(Array(items)) => items.filter_map(decode_ticket_progress)
    _ => []
  }
  // Runtime catalog: absent, null and unknown shapes all decode to "no
  // catalog in this frame" and never fail the snapshot that carries them.
  let model_selection = match fields.get("model_selection") {
    Some(value) => decode_model_catalog(value)
    None => None
  }
  let live = match fields.get("live") {
    Some(value) => decode_ticket_live(value)
    None => None
  }
  {
    project,
    team,
    mcp_servers,
    skills,
    profile,
    questions,
    runs,
    progress,
    live,
    model_selection,
  }
}

///|
/// Decode the optional `model_selection` projection. `selectable` defaults to
/// false: a malformed or partial catalog can only ever make the picker
/// read-only, never make a model look selectable.
fn decode_model_catalog(value : Json) -> ModelCatalog? {
  let fields = match value {
    Object(fields) => fields
    _ => return None
  }
  let selectable = match fields.get("selectable") {
    Some(True) => true
    _ => false
  }
  let kind = match fields.get("kind") {
    Some(String(value)) => value
    _ => ""
  }
  let models = match fields.get("models") {
    Some(Array(items)) => items.filter_map(decode_model_option)
    _ => []
  }
  Some({ selectable, kind, models, })
}

///|
/// One catalog entry. Only the stable slot id is required; labels, efforts
/// and capability hints are optional so a partial host projection still
/// renders instead of disappearing.
fn decode_model_option(value : Json) -> ModelOption? {
  let fields = match value {
    Object(fields) => fields
    _ => return None
  }
  let id = match fields.get("id") {
    Some(String(value)) if value != "" => value
    _ => return None
  }
  let text = name => {
    match fields.get(name) {
      Some(String(value)) => value
      _ => ""
    }
  }
  let strings = name => {
    match fields.get(name) {
      Some(Array(items)) =>
        items.filter_map(item => {
          match item {
            String(value) if value != "" => Some(value)
            _ => None
          }
        })
      _ => []
    }
  }
  let default_effort = match fields.get("default_effort") {
    Some(String(value)) if value != "" => Some(value)
    _ => None
  }
  let context_window = match fields.get("context_window") {
    Some(Number(value, ..)) => Some(value.to_int64())
    _ => None
  }
  Some({
    id,
    label: text("label"),
    provider: text("provider"),
    model: text("model"),
    efforts: strings("efforts"),
    default_effort,
    context_window,
    capabilities: strings("capabilities"),
  })
}

///|
fn decode_ticket_question(value : Json) -> TicketQuestion? {
  let fields = match value {
    Object(fields) => fields
    _ => return None
  }
  let id = match fields.get("id") {
    Some(String(value)) => value
    _ => return None
  }
  let task_id = match fields.get("task_id") {
    Some(String(value)) => value
    _ => return None
  }
  let question = match fields.get("question") {
    Some(String(value)) => value
    _ => return None
  }
  let kind = match fields.get("kind") {
    Some(String(value)) => value
    _ => return None
  }
  let options = match fields.get("options") {
    Some(Array(items)) =>
      items.filter_map(item => {
        match item {
          String(value) => Some(value)
          _ => None
        }
      })
    _ => []
  }
  let asked_at = match fields.get("asked_at") {
    Some(Number(value, ..)) => value.to_int64()
    _ => 0L
  }
  let asked_by = match fields.get("asked_by") {
    Some(String(value)) => value
    _ => "worker"
  }
  let audience = match fields.get("audience") {
    Some(String(value)) => value
    _ => "customer"
  }
  let status = match fields.get("status") {
    Some(String(value)) => value
    _ => "open"
  }
  Some({
    id,
    task_id,
    question,
    kind,
    options,
    asked_at,
    asked_by,
    audience,
    status,
  })
}

///|
/// One worker progress update. `task_id` and a non-blank `message` are the only
/// required fields: without them there is nothing to show, so the entry is
/// dropped instead of failing the snapshot that carries it. An unknown `kind`
/// falls back to `normal`, and a missing or non-numeric `at_ms` reads as the
/// epoch, matching the question decode.
fn decode_ticket_progress(value : Json) -> TicketProgress? {
  let fields = match value {
    Object(fields) => fields
    _ => return None
  }
  let task_id = match fields.get("task_id") {
    Some(String(value)) if value != "" => value
    _ => return None
  }
  let message = match fields.get("message") {
    Some(String(value)) if value.trim() != "" => value
    _ => return None
  }
  let kind = match fields.get("kind") {
    Some(String(value)) => ticket_progress_kind(value)
    _ => "normal"
  }
  let at_ms = match fields.get("at_ms") {
    Some(Number(value, ..)) => value.to_int64()
    _ => 0L
  }
  Some({ task_id, kind, message, at_ms, })
}

///|
/// Bounded tone set of the host contract. An unrecognised kind is still a
/// perfectly good update, so it renders with the neutral tone instead of being
/// dropped or given a colour the stylesheet does not define.
fn ticket_progress_kind(kind : String) -> String {
  match kind {
    "milestone" | "attention" | "blocked" => kind
    _ => "normal"
  }
}

///|
/// Human label of one update tone. The word carries the meaning, so colour is
/// never the only signal.
fn ticket_progress_kind_label(kind : String) -> String {
  match kind {
    "milestone" => "Milestone"
    "attention" => "Attention"
    "blocked" => "Blocked"
    _ => "Update"
  }
}

///|
/// Identity of one update for seen tracking. The host may rewrite its bounded
/// progress list between snapshots, so updates are matched by content rather
/// than by index: the same update delivered twice is still one update.
fn ticket_progress_key(update : TicketProgress) -> String {
  "\{update.task_id}|\{update.at_ms}|\{update.kind}|\{update.message}"
}

///|
fn decode_ticket_live(value : Json) -> TicketLiveInfo? {
  let fields = match value {
    Object(fields) => fields
    _ => return None
  }
  let manager = match fields.get("manager") {
    Some(String(value)) => value
    _ => ""
  }
  let active_model = match fields.get("active_model") {
    Some(String(value)) => value
    _ => ""
  }
  if manager == "" && active_model == "" {
    return None
  }
  let active_effort = match fields.get("active_effort") {
    Some(String(value)) if !value.trim().is_empty() => Some(value)
    _ => None
  }
  let model_count = match fields.get("model_count") {
    Some(Number(value, ..)) => value.to_int()
    _ => 0
  }
  let status = match fields.get("status") {
    Some(Object(status)) => status
    _ => Map([])
  }
  let provider = match status.get("provider") {
    Some(String(value)) => value
    _ => ""
  }
  let status_model = match status.get("model") {
    Some(String(value)) if !value.trim().is_empty() => value
    _ => active_model
  }
  let status_effort = match status.get("effort") {
    Some(String(value)) if !value.trim().is_empty() => Some(value)
    _ => active_effort
  }
  let context_window = match status.get("context_window") {
    Some(Number(value, ..)) if value > 0.0 => Some(value.to_int64())
    _ => None
  }
  let quota_lines : Array[String] = []
  match status.get("quota") {
    Some(Object(quota)) =>
      for key, value in quota {
        match value {
          String(text) => quota_lines.push("\{key}: \{text}")
          _ => ()
        }
      }
    _ => ()
  }
  Some({
    manager,
    active_model: status_model,
    active_effort: status_effort,
    provider,
    context_window,
    model_count,
    quota_lines,
  })
}

///|
/// The progress list newest first. The replica's own array is detached, so
/// ordering never leaks into a previous model.
fn ticket_progress_latest_first(
  updates : Array[TicketProgress],
) -> Array[TicketProgress] {
  let ordered = updates.copy()
  ordered.sort_by((left, right) => right.at_ms.compare(left.at_ms))
  ordered
}

///|
/// Seen set for a set of updates. It is rebuilt from the current list instead
/// of accumulated, so identities the host dropped never linger.
fn ticket_progress_seen(updates : Array[TicketProgress]) -> Map[String, Bool] {
  let seen : Map[String, Bool] = Map([])
  for update in updates {
    seen[ticket_progress_key(update)] = true
  }
  seen
}

///|
/// Keep only the seen identities that are still in the authoritative list. A
/// torn-down worker's updates leave the inbox and their keys leave the model.
fn ticket_progress_retain_seen(
  seen : Map[String, Bool],
  updates : Array[TicketProgress],
) -> Map[String, Bool] {
  let kept : Map[String, Bool] = Map([])
  for update in updates {
    let key = ticket_progress_key(update)
    if seen.contains(key) {
      kept[key] = true
    }
  }
  kept
}

///|
/// Short "how long ago" label for one update. The observation time is passed
/// in so the inbox stays a pure projection and tests can pin it; anything older
/// than a month falls back to UTC civil time instead of an implausible count.
fn ticket_progress_age(at_ms : Int64, now_ms : Int64) -> String {
  let age = now_ms - at_ms
  if age < 3600000L {
    if age < 60000L {
      "just now"
    } else {
      "\{age / 60000L}m ago"
    }
  } else if age < 86400000L {
    "\{age / 3600000L}h ago"
  } else if age < 2592000000L {
    "\{age / 86400000L}d ago"
  } else {
    utc_timestamp(at_ms)
  }
}

///|
/// One inbox update row with everything the renderer needs already resolved.
/// Keeping this projection pure lets tests pin the rendered text and tone
/// without a DOM.
priv struct InboxUpdate {
  task_id : String
  /// Ticket title, or the id when the replica cannot resolve the task.
  title : String
  kind : String
  kind_label : String
  message : String
  at_ms : Int64
  time_label : String
  unseen : Bool
}

///|
/// The update rows the inbox renders, newest first.
fn inbox_updates(model : Model, now_ms : Int64) -> Array[InboxUpdate] {
  ticket_progress_latest_first(model.tickets.progress).map(update => {
    let seen = model.ticket_seen_updates.contains(ticket_progress_key(update))
    {
      task_id: update.task_id,
      title: match task_by_id(model.replica, update.task_id) {
        Some(task) => task.title
        None => update.task_id
      },
      kind: update.kind,
      kind_label: ticket_progress_kind_label(update.kind),
      message: update.message,
      at_ms: update.at_ms,
      time_label: ticket_progress_age(update.at_ms, now_ms),
      unseen: !seen,
    }
  })
}

///|
/// The most recent update of one ticket, if its worker reported any. The
/// Activity dialog shows it above the live run so progress is visible where
/// the run is inspected.
fn ticket_latest_update(model : Model, task_id : String) -> TicketProgress? {
  ticket_progress_latest_first(model.tickets.progress)
  .filter(update => update.task_id == task_id)
  .get(0)
}

///|
fn decode_ticket_activity(value : Json) -> TicketActivity? {
  let fields = match value {
    Object(fields) => fields
    _ => return None
  }
  let text = match fields.get("text") {
    Some(String(value)) => value
    _ => return None
  }
  let kind = match fields.get("kind") {
    Some(String(value)) => value
    _ => "step"
  }
  let at_ms = match fields.get("at_ms") {
    Some(Number(value, ..)) => value.to_int64()
    _ => 0L
  }
  Some({ at_ms, kind, text, })
}

///|
fn decode_ticket_run(value : Json) -> TicketRun? {
  let fields = match value {
    Object(fields) => fields
    _ => return None
  }
  let task_id = match fields.get("task_id") {
    Some(String(value)) => value
    _ => return None
  }
  let session_id = match fields.get("session_id") {
    Some(String(value)) => value
    _ => ""
  }
  let phase = match fields.get("phase") {
    Some(String(value)) => value
    _ => "work"
  }
  let role = match fields.get("role") {
    Some(String(value)) => value
    _ => ""
  }
  let status = match fields.get("status") {
    Some(String(value)) => value
    _ => "running"
  }
  let error = match fields.get("error") {
    Some(String(value)) => Some(value)
    _ => None
  }
  let result = match fields.get("result") {
    Some(String(value)) => Some(value)
    _ => None
  }
  let steps = match fields.get("steps") {
    Some(Number(value, ..)) => value.to_int()
    _ => 0
  }
  let current_tool = match fields.get("current_tool") {
    Some(String(value)) => Some(value)
    _ => None
  }
  let preview = match fields.get("preview") {
    Some(String(value)) => value
    _ => ""
  }
  let reasoning = match fields.get("reasoning") {
    Some(String(value)) => value
    _ => ""
  }
  let activities = match fields.get("activities") {
    Some(Array(items)) => items.filter_map(decode_ticket_activity)
    _ => []
  }
  Some({
    task_id,
    session_id,
    phase,
    role,
    status,
    error,
    result,
    steps,
    current_tool,
    preview,
    reasoning,
    activities,
  })
}

///|
fn ticket_frame(text : String) -> TicketFrame? {
  let parsed = @json.parse(text) catch { _ => return None }
  let fields = match parsed {
    Object(fields) => fields
    _ => return None
  }
  match fields.get("type") {
    Some(String("ticket_state")) =>
      match fields.get("state") {
        Some(state) => Some(TicketSnapshot(ticket_state_from_json(state)))
        None => None
      }
    Some(String("ticket_result")) => {
      let ok = match fields.get("ok") {
        Some(True) => true
        _ => false
      }
      let reason = match fields.get("reason") {
        Some(String(value)) => Some(value)
        _ => None
      }
      let state = match fields.get("state") {
        Some(state) => Some(ticket_state_from_json(state))
        None => None
      }
      Some(TicketOutcome(ok, reason, state))
    }
    _ => None
  }
}

///|
/// Wire frame for one ticket command. Kept separate from the socket send so
/// tests can pin the exact command name and arguments.
fn ticket_command_frame(name : String, args : Json) -> String {
  let frame : Json = {
    "type": "ticket_command",
    "name": Json::string(name),
    "args": args,
  }
  frame.stringify()
}

///|
fn send_ticket_command(
  name : String,
  args : Json,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  @websocket.send("board", Text(ticket_command_frame(name, args)), failed=_ => {
    emit(
      TicketResult(false, Some("The ticket command could not be sent."), None),
    )
  })
}

///|
fn team_mcp_json(mcp : Map[String, TeamMcp]) -> Json {
  let fields : Map[String, Json] = Map([])
  for role in ["po", "sm", "rd", "set", "te"] {
    let value = match mcp.get(role) {
      Some(value) => value
      None => TeamMcp::defaults()
    }
    fields[role] = Json::object({
      "enabled": Json::boolean(value.enabled),
      "all": Json::boolean(value.all),
      "servers": Json::array(value.servers.map(Json::string)),
      "tools": Json::array(value.tools.map(Json::string)),
    })
  }
  Json::object(fields)
}

///|
fn team_skills_json(skills : Map[String, TeamSkills]) -> Json {
  let fields : Map[String, Json] = Map([])
  for role in ["po", "sm", "rd", "set", "te"] {
    let value = match skills.get(role) {
      Some(value) => value
      None => TeamSkills::defaults()
    }
    fields[role] = Json::object({
      "enabled": Json::boolean(value.enabled),
      "all": Json::boolean(value.all),
      "skills": Json::array(value.skills.map(Json::string)),
    })
  }
  Json::object(fields)
}

///|
fn ticket_set_required_roles(
  task_id : String,
  roles : Array[String],
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  send_ticket_command(
    "board.ticket.set_required_roles",
    {
      "id": Json::string(task_id),
      "roles": Json::array(roles.map(Json::string)),
    },
    emit,
  )
}

///|
fn ticket_set_team(
  names : TeamNames,
  profile : WorkProfile,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  let args : Json = {
    "po": Json::string(names.po.trim().to_owned()),
    "sm": Json::string(names.sm.trim().to_owned()),
    "rd": Json::string(names.rd.trim().to_owned()),
    "set": Json::string(names.set.trim().to_owned()),
    "te": Json::string(names.te.trim().to_owned()),
    "mcp": team_mcp_json(names.mcp),
    "skills": team_skills_json(names.skills),
    "work_profile": Json::string(profile.id),
  }
  send_ticket_command("board.ticket.set_team", args, emit)
}

///|
fn ticket_answer_as_refiner(
  question_id : String,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  send_ticket_command(
    "board.ticket.answer_as_refiner",
    { "question_id": Json::string(question_id) },
    emit,
  )
}

///|
fn ticket_run_ready(emit : @rabbita.Emit[Msg]) -> @rabbita.Cmd {
  send_ticket_command("board.ticket.run_ready", Json::object(Map([])), emit)
}

///|
fn ticket_answer(
  question_id : String,
  answer : TicketAnswer,
  emit : @rabbita.Emit[Msg],
  answered_by~ : String = "customer",
) -> @rabbita.Cmd {
  let args : Json = match answer {
    TicketText(value) =>
      {
        "question_id": Json::string(question_id),
        "text": Json::string(value),
        "answered_by": Json::string(answered_by),
      }
    TicketConfirm(value) =>
      {
        "question_id": Json::string(question_id),
        "confirm": Json::boolean(value),
        "answered_by": Json::string(answered_by),
      }
    TicketSelect(value) =>
      {
        "question_id": Json::string(question_id),
        "index": Json::number(value.to_double()),
        "answered_by": Json::string(answered_by),
      }
  }
  send_ticket_command("board.ticket.answer", args, emit)
}

///|
fn ticket_run_for(model : Model, task_id : String) -> TicketRun? {
  let runs = model.tickets.runs.filter(run => run.task_id == task_id)
  for run in runs {
    if run.status == "running" {
      return Some(run)
    }
  }
  runs.get(runs.length() - 1)
}

///|
/// A run that failed in place is still Recovery C state: keep the ticket in its
/// lane, paint it as an error, and offer Resume run/Retry work instead of a
/// stage move to Paused.
fn ticket_task_failed(model : Model, task_id : String) -> Bool {
  match ticket_run_for(model, task_id) {
    Some(run) => ticket_run_retryable(run.status)
    None => false
  }
}

///|
fn ticket_task_running(model : Model, task_id : String) -> Bool {
  model.tickets.runs.any(run => {
    run.task_id == task_id && run.status == "running"
  })
}

///|
fn is_customer_question(question : TicketQuestion) -> Bool {
  question.audience == "customer" || question.audience == "product_owner" || question.audience == "sm"
}

///|
fn ticket_question_count(model : Model) -> Int32 {
  model.tickets.questions.filter(is_customer_question).length()
}

///|
/// Worker updates the user has not looked at yet. Opening the inbox records the
/// list that was on screen as seen; anything a worker reports afterwards is
/// unseen again until the next open.
fn ticket_unseen_update_count(model : Model) -> Int32 {
  model.tickets.progress
  .filter(update => {
    !model.ticket_seen_updates.contains(ticket_progress_key(update))
  })
  .length()
}

///|
/// The inbox badge counts both things waiting for a human: open questions that
/// need an answer, and worker updates that arrived since the inbox was opened.
fn ticket_inbox_count(model : Model) -> Int32 {
  ticket_question_count(model) + ticket_unseen_update_count(model)
}

///|
/// Header and section wording for the unseen updates. Plain words, never a raw
/// count with no noun.
fn ticket_update_count_label(count : Int32) -> String {
  if count == 1 {
    "1 new update"
  } else {
    "\{count} new updates"
  }
}

///|
/// Total update count for the header chip, separate from the unseen count so
/// the inbox still reports how much the workers said when nothing is new.
fn ticket_update_total_label(count : Int32) -> String {
  if count == 1 {
    "1 update"
  } else {
    "\{count} updates"
  }
}

///|
fn ticket_shape(task_id : String, emit : @rabbita.Emit[Msg]) -> @rabbita.Cmd {
  let args : Json = { "task_id": Json::string(task_id) }
  send_ticket_command("board.ticket.shape", args, emit)
}

///|
fn ticket_run(task_id : String, emit : @rabbita.Emit[Msg]) -> @rabbita.Cmd {
  let args : Json = { "task_id": Json::string(task_id) }
  send_ticket_command("board.ticket.run", args, emit)
}

///|
/// Wire arguments for one retry. The host resolves them to a brand-new run for
/// the ticket; nothing about the previous child session travels on the wire.
fn ticket_retry_args(task_id : String) -> Json {
  { "task_id": Json::string(task_id) }
}

///|
fn ticket_retry(task_id : String, emit : @rabbita.Emit[Msg]) -> @rabbita.Cmd {
  send_ticket_command("board.ticket.retry", ticket_retry_args(task_id), emit)
}

///|
/// Wire arguments for one resume. The host continues the durable child session
/// the interrupted run already owns, so only the ticket identity travels: the
/// session itself stays authoritative on the host.
fn ticket_resume_args(task_id : String) -> Json {
  { "task_id": Json::string(task_id) }
}

///|
fn ticket_resume(task_id : String, emit : @rabbita.Emit[Msg]) -> @rabbita.Cmd {
  send_ticket_command("board.ticket.resume", ticket_resume_args(task_id), emit)
}

///|
/// Wire arguments for one Request changes round: which ticket is going back and
/// the reviewer note the next run must address. The note is the reason the
/// command exists, so it is trimmed and never empty when it leaves here.
fn ticket_request_changes_args(task_id : String, feedback : String) -> Json {
  {
    "task_id": Json::string(task_id),
    "feedback": Json::string(feedback.trim().to_owned()),
  }
}

///|
/// Request changes is a ticket command, not an attempt decision: the host
/// records ChangesRequested, moves the task Review → Ready and starts a fresh
/// work run from the feedback.
fn ticket_request_changes(
  task_id : String,
  feedback : String,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  send_ticket_command(
    "board.ticket.request_changes",
    ticket_request_changes_args(task_id, feedback),
    emit,
  )
}

///|
/// Why Request changes cannot be sent right now, in the same order the gate
/// checks it. The host rejects a blank note, so the editor states every reason
/// instead of leaving the submit button silently disabled.
fn ticket_request_changes_hint(model : Model, feedback : String) -> String? {
  if model.ticket_sending {
    Some("Wait for the current ticket command to finish.")
  } else if !model.can_connect {
    Some("Reconnect to the board before sending feedback.")
  } else if !model.ticket_available {
    Some(ticket_rejection_text(Some("ticket_runtime_unavailable")))
  } else if feedback.trim().is_empty() {
    Some("Write the feedback the next run must address.")
  } else {
    None
  }
}

///|
fn ticket_request_changes_blocked(model : Model, feedback : String) -> Bool {
  ticket_request_changes_hint(model, feedback) is Some(_)
}

///|
/// Finished run statuses that left no live worker behind. Only these offer
/// Retry work: a succeeded run is a result to review, not a lost session, and
/// a running one is still owned by its worker.
fn ticket_run_retryable(status : String) -> Bool {
  match status {
    "failed" | "interrupted" | "sync_failed" => true
    _ => false
  }
}

///|
/// A finished run keeps its durable session in these states. A network or work
/// failure is recoverable: Resume run continues the recorded session, while
/// Retry remains the fresh-attempt escape hatch. A blank session id means there
/// is nothing to continue.
fn ticket_run_resumable(run : TicketRun) -> Bool {
  ticket_run_retryable(run.status) && run.session_id != ""
}

///|
/// Every ticket command waits for the in-flight one to clear, needs a socket
/// that can carry it and an advertised runtime, and never fires while this
/// ticket already has a live run.
fn ticket_command_blocked(model : Model, task_id : String) -> Bool {
  model.ticket_sending ||
  !model.can_connect ||
  !model.ticket_available ||
  ticket_task_running(model, task_id)
}

///|
/// Retry work shares the ticket-command gate with every other ticket command.
fn ticket_retry_blocked(model : Model, task_id : String) -> Bool {
  ticket_command_blocked(model, task_id)
}

///|
/// Resume run is gated exactly like Retry: the two offers sit in the same block
/// and must never race each other.
fn ticket_resume_blocked(model : Model, task_id : String) -> Bool {
  ticket_command_blocked(model, task_id)
}

///|
fn ticket_retry_note() -> String {
  "Retry starts a new run from the current ticket. It does not resume the lost session, so the previous worker's context is gone."
}

///|
/// Retry work plus the note that states its consequence. The ticket stays in
/// place: unlike Resume, this action starts a run instead of moving a stage.
fn ticket_retry_action(
  model : Model,
  task_id : String,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  @html.div(class="ticket-retry", [
    @html.div(class="ticket-answers", [
      @html.button(
        type_="button",
        class="btn btn-sm btn-primary",
        title="Start a fresh run for this ticket",
        disabled=ticket_retry_blocked(model, task_id),
        on_click=emit(TicketRetry(task_id)),
        "Retry work",
      ),
    ]),
    @html.p(class="ticket-retry-note", ticket_retry_note()),
  ])
}

///|
/// The action one finished run offers under its card. Resume run continues the
/// durable session the interrupted run already owns; Retry starts a new run and
/// clears it.
priv enum TicketRunAction {
  ResumeRun
  RetryRun
}

///|
/// The actions one finished run offers, primary first. A recoverable run with a
/// durable session prefers continuing it, so Resume run comes first and Retry
/// follows as the fresh-attempt escape hatch; a run whose session did not
/// survive only offers Retry.
fn ticket_run_actions(run : TicketRun) -> Array[TicketRunAction] {
  let actions : Array[TicketRunAction] = []
  if ticket_run_resumable(run) {
    actions.push(ResumeRun)
  }
  if ticket_run_retryable(run.status) {
    actions.push(RetryRun)
  }
  actions
}

///|
/// Resume run and Retry mean different things, so the interrupted card states
/// both consequences instead of leaving the user to guess which one keeps
/// context. The label keeps "run" so it never reads as the ticket's own
/// Suspended → Ready Resume move.
fn ticket_resume_note() -> String {
  "Resume run continues the durable session where it stopped. Retry starts a new run and clears it."
}

///|
/// The visible label of one finished-run action. Resume run stays distinct from
/// the card's own Suspended → Ready Resume stage move.
fn ticket_run_action_label(action : TicketRunAction) -> String {
  match action {
    ResumeRun => "Resume run"
    RetryRun => "Retry work"
  }
}

///|
fn ticket_run_action_button(
  model : Model,
  task_id : String,
  action : TicketRunAction,
  primary : Bool,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let button_class = if primary {
    "btn btn-sm btn-primary"
  } else {
    "btn btn-sm"
  }
  match action {
    ResumeRun =>
      @html.button(
        type_="button",
        class=button_class,
        title="Resume run: continue this run's durable session",
        disabled=ticket_resume_blocked(model, task_id),
        on_click=emit(TicketResume(task_id)),
        ticket_run_action_label(action),
      )
    RetryRun =>
      @html.button(
        type_="button",
        class=button_class,
        title="Start a fresh run for this ticket",
        disabled=ticket_retry_blocked(model, task_id),
        on_click=emit(TicketRetry(task_id)),
        ticket_run_action_label(action),
      )
  }
}

///|
/// Resume and Retry for one finished run card, or nothing when that run still
/// holds a live worker or already produced a result worth keeping. The gate only
/// disables the buttons: an interrupted run keeps offering both while the
/// socket reconnects.
fn ticket_run_action_block(
  model : Model,
  run : TicketRun,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let actions = ticket_run_actions(run)
  if actions.is_empty() {
    return @html.nothing
  }
  let buttons : Array[@html.Html] = []
  for index, action in actions {
    buttons.push(
      ticket_run_action_button(model, run.task_id, action, index == 0, emit),
    )
  }
  let resumable = actions.any(action => action is ResumeRun)
  @html.div(class="ticket-run-actions", [
    @html.div(class="ticket-answers", buttons),
    @html.p(
      class="ticket-run-actions-note",
      if resumable {
        ticket_resume_note()
      } else {
        ticket_retry_note()
      },
    ),
  ])
}

///|
/// A paused ticket that never started a run has no card to retry, so the
/// dialog still offers Retry work next to the ticket's own Resume move.
fn ticket_stage_retry_action(
  model : Model,
  task : @client.ClientBoardTask?,
  task_id : String,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let has_run = model.tickets.runs.any(run => run.task_id == task_id)
  match task {
    Some(task) if task.stage is @client.Suspended && !has_run =>
      ticket_retry_action(model, task_id, emit)
    _ => @html.nothing
  }
}

///|
/// Wire arguments for one ticket model change. Kept separate from the send so
/// tests can pin the exact payload: the stable slot id (not the model id) and
/// an explicit `null` model when the ticket returns to inherit.
fn ticket_set_model_args(task_id : String, model : ModelChoice?) -> Json {
  let payload : Json = match model {
    Some(choice) =>
      {
        "slot": Json::string(choice.slot),
        "effort": match choice.effort {
          Some(effort) => Json::string(effort)
          None => Json::null()
        },
      }
    None => Json::null()
  }
  { "task_id": Json::string(task_id), "model": payload }
}

///|
fn ticket_set_model(
  task_id : String,
  model : ModelChoice?,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  send_ticket_command(
    "board.ticket.set_model",
    ticket_set_model_args(task_id, model),
    emit,
  )
}

///|
fn ticket_dismiss(task_id : String, emit : @rabbita.Emit[Msg]) -> @rabbita.Cmd {
  let args : Json = { "task_id": Json::string(task_id) }
  send_ticket_command("board.ticket.dismiss", args, emit)
}

///|
fn ticket_dismiss_updates(emit : @rabbita.Emit[Msg]) -> @rabbita.Cmd {
  send_ticket_command(
    "board.ticket.dismiss_progress",
    Json::object(Map([])),
    emit,
  )
}

///|
fn ticket_activity_list(activities : Array[TicketActivity]) -> @html.Html {
  let items : Array[@html.Html] = []
  let start = if activities.length() > 20 {
    activities.length() - 20
  } else {
    0
  }
  for index in start..<activities.length() {
    let activity = activities[index]
    items.push(
      @html.div(
        class="ticket-activity-row kind-\{activity.kind}",
        @html.span(class="ticket-activity-text", activity.text),
      ),
    )
  }
  @html.div(class="ticket-activity-list", items)
}

///|
fn ticket_run_card(model : Model, run : TicketRun) -> @html.Html {
  let title = match task_by_id(model.replica, run.task_id) {
    Some(task) => task.title
    None => run.task_id
  }
  let phase = if run.phase == "shape" {
    "Shaping"
  } else {
    match run.role {
      "" => "Working"
      "te" => "Verification · " + team_member_label(model, run.role)
      role => "Working · " + team_member_label(model, role)
    }
  }
  let tool = match run.current_tool {
    Some(name) => " · " + name
    None => ""
  }
  let preview = if run.preview == "" {
    "Waiting for the first model response…"
  } else {
    run.preview
  }
  @html.div(class="ticket-question ticket-run", [
    @html.div(class="ticket-question-meta", [
      @html.span(class="ticket-question-task", title),
      @html.span(class="ticket-question-kind", phase + tool),
    ]),
    // The newest worker update sits above the live preview: it is the same
    // information the inbox shows, repeated where the run is inspected.
    match ticket_latest_update(model, run.task_id) {
      Some(update) =>
        @html.div(class="ticket-update is-compact kind-\{update.kind}", [
          @html.span(
            class="ticket-update-kind",
            ticket_progress_kind_label(update.kind),
          ),
          @html.span(class="ticket-update-text", update.message),
        ])
      None => @html.nothing
    },
    @html.div(class="ticket-run-preview", preview),
    if run.reasoning == "" {
      @html.nothing
    } else {
      @html.details(class="ticket-reasoning", [
        @html.summary("Reasoning"),
        @html.div(class="ticket-reasoning-text", run.reasoning),
      ])
    },
    ticket_activity_list(run.activities),
    @html.div(
      class="ticket-run-foot",
      "Step \{run.steps} · updates automatically while the worker runs.",
    ),
  ])
}

///|
fn ticket_result_card(
  model : Model,
  run : TicketRun,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let title = match task_by_id(model.replica, run.task_id) {
    Some(task) => task.title
    None => run.task_id
  }
  @html.div(class="ticket-question ticket-result", [
    @html.div(class="ticket-question-meta", [
      @html.span(class="ticket-question-task", title),
      @html.span(class="ticket-question-kind", run.status),
    ]),
    @html.div(
      class=if run.error is Some(_) {
        "ticket-result-text ticket-result-error"
      } else {
        "ticket-result-text"
      },
      match run.result {
        Some(text) => text
        None =>
          match run.error {
            Some(text) => text
            None => "No result recorded."
          }
      },
    ),
    if run.activities.is_empty() {
      @html.nothing
    } else {
      ticket_activity_list(run.activities)
    },
    ticket_run_action_block(model, run, emit),
    @html.div(class="ticket-answers", [
      @html.button(
        type_="button",
        class="btn btn-sm",
        disabled=model.ticket_sending,
        on_click=emit(TicketResultDismissed(run.task_id)),
        "Dismiss",
      ),
    ]),
  ])
}

///|
fn apply_ticket_state(model : Model, state : TicketState) -> Model {
  // The catalog is runtime projection, not ticket journal state: a frame that
  // omitted it (for example a `ticket_result`) keeps the last known catalog
  // instead of disabling a picker the user is looking at.
  let model_selection = match state.model_selection {
    Some(_) => state.model_selection
    None => model.tickets.model_selection
  }
  let live = match state.live {
    Some(_) => state.live
    None => model.tickets.live
  }
  let project = if state.project == "" {
    model.tickets.project
  } else {
    state.project
  }
  let team = match state.team {
    Some(_) => state.team
    None => model.tickets.team
  }
  {
    ..model,
    tickets: { ..state, project, team, live, model_selection, },
    // Only the updates still on the wire stay "seen": a worker that tore down
    // takes its updates with it, so its identities must not linger.
    ticket_seen_updates: ticket_progress_retain_seen(
      model.ticket_seen_updates,
      state.progress,
    ),
    ticket_available: true,
    ticket_sending: false,
  }
}

///|
fn ticket_rejection_text(reason : String?) -> String {
  match reason {
    Some("ticket is already running") =>
      "This ticket is already running. Open its Activity dialog to inspect progress."
    Some("ticket must be Backlog, Shaping, or Ready before it can be shaped") =>
      "Move the ticket back to Backlog or Shaping before shaping it again."
    Some("ticket must be Ready before it can run") =>
      "Shape the ticket and move it to Ready before starting work."
    Some("ticket_runtime_unavailable") =>
      "The Board ticket runtime is unavailable. Restart Cetas with workflows enabled."
    Some("ticket_start_failed") | Some("ticket_shape_failed") =>
      "The ticket could not start. Open its Activity dialog for the failure detail."
    Some(text) if text != "" => text
    _ => "The ticket command was rejected."
  }
}

///|
fn apply_ticket_outcome(
  model : Model,
  ok : Bool,
  reason : String?,
  state : TicketState?,
) -> Model {
  let next = match state {
    Some(state) => apply_ticket_state(model, state)
    None =>
      ({ ..model, ticket_available: true, ticket_sending: false, } : Model)
  }
  if ok {
    { ..next, last_status: "Ticket updated", }
  } else {
    let already_running = reason == Some("ticket is already running")
    {
      ..next,
      notice: Some(
        notice(
          Warning,
          if already_running {
            "This ticket is already running. Open its Activity dialog to inspect progress."
          } else {
            ticket_rejection_text(reason)
          },
        ),
      ),
    }
  }
}

///|
fn ready_ticket_count(model : Model) -> Int32 {
  model.replica.tasks().filter(task => task.stage == @client.Ready).length()
}

///|
fn team_member_label(model : Model, role : String) -> String {
  let team = match model.tickets.team {
    Some(team) => team
    None => TeamNames::defaults()
  }
  match role {
    "product_owner" | "customer" => "Customer"
    "refiner" | "po" => team.po
    "sm" => team.sm
    "rd" => team.rd
    "set" => team.set
    "te" => team.te
    "development_group" | "worker" => "Development"
    _ => role
  }
}

///|
fn ticket_question_card(
  model : Model,
  question : TicketQuestion,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let title = match task_by_id(model.replica, question.task_id) {
    Some(task) => task.title
    None => question.task_id
  }
  let draft = model.ticket_drafts.get(question.id).unwrap_or("")
  let refiner_name = team_member_label(model, "po")
  let answer_controls = match question.kind {
    "confirm" =>
      @html.div(class="ticket-answers", [
        @html.button(
          type_="button",
          class="btn btn-sm",
          disabled=model.ticket_sending,
          on_click=emit(TicketAnswered(question.id, TicketConfirm(true))),
          "Yes",
        ),
        @html.button(
          type_="button",
          class="btn btn-sm",
          disabled=model.ticket_sending,
          on_click=emit(TicketAnswered(question.id, TicketConfirm(false))),
          "No",
        ),
      ])
    "select" => {
      let buttons : Array[@html.Html] = []
      for index in 0..<question.options.length() {
        buttons.push(
          @html.button(
            type_="button",
            class="btn btn-sm",
            disabled=model.ticket_sending,
            on_click=emit(TicketAnswered(question.id, TicketSelect(index))),
            question.options[index],
          ),
        )
      }
      @html.div([
        @html.div(class="ticket-answers", buttons),
        @html.div(class="ticket-other", [
          @html.div(class="ticket-other-label", "Other answer"),
          @html.div(class="ticket-answers", [
            @ui.text_area(
              id="ticket-other-\{question.id}",
              name="ticket_other",
              value=draft,
              rows=3,
              placeholder="None of these fit? Write your answer…",
              disabled=model.ticket_sending,
              on_input=value => emit(TicketDraftChanged(question.id, value)),
            ),
            @html.button(
              type_="button",
              class="btn btn-sm btn-primary",
              disabled=model.ticket_sending || draft.trim().is_empty(),
              on_click=emit(TicketAnswered(question.id, TicketText(draft))),
              "Send other",
            ),
            @html.button(
              type_="button",
              class="btn btn-sm",
              disabled=model.ticket_sending || draft.trim().is_empty(),
              on_click=emit(TicketAnsweredAsRefiner(question.id, draft)),
              "Answer as " + refiner_name,
            ),
          ]),
        ]),
      ])
    }
    _ =>
      @html.div(class="ticket-answers", [
        @ui.text_area(
          id="ticket-answer-\{question.id}",
          name="ticket_answer",
          value=draft,
          rows=4,
          placeholder="Write your answer or feedback…",
          disabled=model.ticket_sending,
          on_input=value => emit(TicketDraftChanged(question.id, value)),
        ),
        @html.button(
          type_="button",
          class="btn btn-sm btn-primary",
          disabled=model.ticket_sending || draft.trim().is_empty(),
          on_click=emit(TicketAnswered(question.id, TicketText(draft))),
          "Send",
        ),
        @html.button(
          type_="button",
          class="btn btn-sm",
          disabled=model.ticket_sending || draft.trim().is_empty(),
          on_click=emit(TicketAnsweredAsRefiner(question.id, draft)),
          "Answer as " + refiner_name,
        ),
      ])
  }
  @html.div(class="ticket-question", [
    @html.div(class="ticket-question-meta", [
      @html.span(class="ticket-question-task", title),
      @html.span(class="ticket-question-kind", question.kind),
      @html.span(
        class="ticket-question-route",
        "\{team_member_label(model, question.asked_by)} → \{team_member_label(model, question.audience)}",
      ),
    ]),
    @html.div(class="ticket-question-text", question.question),
    answer_controls,
    @html.div(class="ticket-answers", [
      @html.button(
        type_="button",
        class="btn btn-sm",
        disabled=model.ticket_sending,
        on_click=emit(TicketRefinerRequested(question.id)),
        "Ask " + refiner_name,
      ),
    ]),
  ])
}

///|
/// Per-ticket Activity dialog: live and finished runs belong to the ticket,
/// not to the question inbox.
fn ticket_activity_dialog(
  model : Model,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let task_id = match model.ticket_activity_task {
    Some(task_id) => task_id
    None =>
      // The element must exist before the Activity click can open it: `ui_show`
      // looks the dialog up by id, so a dialog rendered only for a selected
      // ticket would be missing on the very first click.
      return @ui.sheet_dialog(
        "ticket-activity-dialog",
        "Ticket activity",
        _ => emit(TicketActivityClosed),
        "40rem",
        [
          @html.div(class="sheet", [
            @html.p(class="section-note", "Open a ticket to see its activity."),
          ]),
        ],
      )
  }
  let task = task_by_id(model.replica, task_id)
  let title = match task {
    Some(task) => task.title
    None => task_id
  }
  let runs = model.tickets.runs.filter(run => run.task_id == task_id)
  let run_label = if runs.length() == 1 {
    "1 run"
  } else {
    "\{runs.length()} runs"
  }
  @ui.sheet_dialog(
    "ticket-activity-dialog",
    "Ticket activity",
    _ => emit(TicketActivityClosed),
    "40rem",
    [
      @html.div(class="sheet", [
        @html.header(class="sheet-head", [
          @html.div(class="sheet-heading", [
            @html.nav(
              class="crumbs",
              attrs=@html.Attrs::build().aria_label("Breadcrumb"),
              [
                @html.button(
                  type_="button",
                  class="crumb-link",
                  attrs=@html.Attrs::build().on_click(_ => {
                    ui_close("ticket-activity-dialog")
                    @rabbita.none
                  }),
                  "Board",
                ),
                @html.span(class="crumb-sep", "/"),
                @html.span(class="crumb-here", title),
                @html.span(class="crumb-sep", "/"),
                @html.span(class="crumb-here", "Activity"),
              ],
            ),
            @html.h2(class="sheet-title", "Activity"),
            @html.p(class="sheet-meta", [
              @ui.chip(
                if runs.is_empty() {
                  "No runs yet"
                } else {
                  run_label
                },
                @ui.ChipTone::Quiet,
              ),
              @ui.chip(task_id, @ui.ChipTone::Quiet),
            ]),
          ]),
        ]),
        @html.div(
          class="sheet-body ticket-activity-body",
          if runs.is_empty() {
            [
              @html.div(
                class="empty-line",
                "No agent activity yet. Shape or run this ticket to start.",
              ),
              ticket_stage_retry_action(model, task, task_id, emit),
            ]
          } else {
            runs.map(run => {
              if run.status == "running" {
                ticket_run_card(model, run)
              } else {
                ticket_result_card(model, run, emit)
              }
            })
          },
        ),
      ]),
    ],
  )
}

///|
/// One inbox update row. It is information only: no answer control, no stage
/// move and no dismiss, because the worker owns the run and the host owns the
/// list.
fn ticket_update_card(update : InboxUpdate) -> @html.Html {
  let unseen = if update.unseen { " is-unseen" } else { "" }
  @html.article(class="ticket-update kind-\{update.kind}\{unseen}", [
    @html.div(class="ticket-update-meta", [
      @html.span(class="ticket-update-task", title=update.task_id, update.title),
      @html.span(class="ticket-update-kind", update.kind_label),
      if update.unseen {
        @html.span(class="ticket-update-new", "New")
      } else {
        @html.nothing
      },
      @html.span(
        class="ticket-update-time",
        title=utc_timestamp(update.at_ms),
        update.time_label,
      ),
    ]),
    @html.p(class="ticket-update-text", update.message),
  ])
}

///|
/// The Updates block. It sits above the questions because it is the freshest
/// thing the workers said, and it states in words that no reply is expected so
/// an update never reads as an unanswered question.
fn ticket_updates_section(
  updates : Array[InboxUpdate],
  unseen_count : Int32,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  @html.section(
    class="inbox-updates",
    attrs=@html.Attrs::build().aria_label("Worker updates"),
    [
      @html.header(class="inbox-section-head", [
        @html.h3(class="inbox-section-title", "Updates"),
        @html.span(
          class="inbox-section-hint",
          if unseen_count == 0 {
            "Information only — no reply needed."
          } else {
            "Information only — \{ticket_update_count_label(unseen_count)} since you last opened the inbox."
          },
        ),
        @html.button(
          type_="button",
          class="btn btn-sm inbox-dismiss",
          title="Dismiss these updates",
          attrs=@html.Attrs::build().on_click(_ => emit(TicketUpdatesDismissed)),
          "Dismiss",
        ),
      ]),
      @html.div(
        class="inbox-update-list",
        updates.map(update => ticket_update_card(update)),
      ),
    ],
  )
}

///|
/// The inbox holds two different things: questions that need a human answer,
/// and worker updates that need nothing. Live and finished run detail lives on
/// the ticket's own Activity dialog.
fn inbox_dialog(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let question_count = ticket_question_count(model)
  let update_count = model.tickets.progress.length()
  let unseen_count = ticket_unseen_update_count(model)
  let updates = inbox_updates(model, board_now_ms())
  let items : Array[@html.Html] = []
  if !updates.is_empty() {
    items.push(ticket_updates_section(updates, unseen_count, emit))
  }
  for question in model.tickets.questions {
    if is_customer_question(question) {
      items.push(ticket_question_card(model, question, emit))
    }
  }
  if question_count == 0 {
    items.push(@html.div(class="empty-line", "No open questions."))
  }
  @ui.sheet_dialog(
    "inbox-dialog",
    "Ticket inbox",
    _ => emit(TicketDrawerClosed),
    "34rem",
    [
      @html.div(class="sheet", [
        @html.header(class="sheet-head", [
          @html.div(class="sheet-heading", [
            @html.nav(
              class="crumbs",
              attrs=@html.Attrs::build().aria_label("Breadcrumb"),
              [
                @html.button(
                  type_="button",
                  class="crumb-link",
                  attrs=@html.Attrs::build().on_click(_ => {
                    ui_close("inbox-dialog")
                    @rabbita.none
                  }),
                  "Board",
                ),
                @html.span(class="crumb-sep", "/"),
                @html.span(class="crumb-here", "Inbox"),
              ],
            ),
            @html.h2(class="sheet-title", "Inbox"),
            @html.p(class="sheet-meta", [
              if question_count == 0 {
                @ui.chip("No open questions", @ui.ChipTone::Quiet)
              } else {
                @ui.chip(
                  "\{question_count} awaiting an answer",
                  @ui.ChipTone::Pinned,
                )
              },
              if update_count == 0 {
                @html.nothing
              } else {
                @ui.chip(
                  ticket_update_total_label(update_count),
                  @ui.ChipTone::Quiet,
                )
              },
              if unseen_count == 0 {
                @html.nothing
              } else {
                @ui.chip(
                  ticket_update_count_label(unseen_count),
                  @ui.ChipTone::Running,
                )
              },
            ]),
          ]),
        ]),
        @html.div(class="sheet-body inbox-body", items),
      ]),
    ],
  )
}
