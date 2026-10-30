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

