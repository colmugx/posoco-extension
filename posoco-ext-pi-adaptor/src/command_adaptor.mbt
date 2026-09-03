///|
/// Pi slash-command bridge: projects the shared JS host's registerCommand /
/// registerShortcut surfaces onto the Posoco CommandPort. All pi commands
/// present as `pi:<name>` CommandDefs (coexistence namespace — unlike tools,
/// commands never hide or get hidden); shortcuts ride as invisible
/// shortcut-only defs (`pi:#<key>`) so the terminal-shell keybinding pass
/// picks up their `shortcut` field while autocomplete stays clean.
pub struct PiCommandPort {
  host : JsPiHost
}

///|
pub fn PiCommandPort::PiCommandPort(host~ : JsPiHost) -> PiCommandPort {
  { host, }
}

///|
fn pi_json_string_or(fields : Map[String, Json], key : String) -> String {
  match fields.get(key) {
    Some(Json::String(value)) => value
    _ => ""
  }
}

///|
fn pi_command_def(
  name : String,
  description : String,
  source : Json,
) -> @posoco.CommandDef {
  {
    id: "pi:" + name,
    label: name,
    description,
    category: "pi",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: true,
    metadata: Some(source),
  }
}

///|
fn pi_shortcut_def(
  key : String,
  description : String,
  source : Json,
) -> @posoco.CommandDef {
  {
    id: "pi:#" + key,
    label: key,
    description,
    category: "pi",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: Some(key),
    icon: None,
    visible: false,
    metadata: Some(source),
  }
}

///|
/// CommandDef list over the live host state. Late registrations stay visible
/// because ports are consulted per listing/invocation; duplicate names (pi
/// does not dedupe) collapse to the first so the composition-time id
/// collision check cannot fail on a re-registering package.
fn PiCommandPort::defs(self : PiCommandPort) -> Array[@posoco.CommandDef] {
  let defs : Array[@posoco.CommandDef] = []
  let seen : Map[String, Bool] = Map::from_array([])
  match parse_json_or_null(js_commands_json(self.host)) {
    Json::Array(items) =>
      for item in items {
        match item {
          Json::Object(fields) => {
            let name = pi_json_string_or(fields, "name")
            if name.length() > 0 && !seen.contains(name) {
              seen[name] = true
              defs.push(
                pi_command_def(
                  name,
                  pi_json_string_or(fields, "description"),
                  item,
                ),
              )
            }
          }
          _ => ()
        }
      }
    _ => ()
  }
  match parse_json_or_null(js_shortcuts_json(self.host)) {
    Json::Array(items) =>
      for item in items {
        match item {
          Json::Object(fields) => {
            let key = pi_json_string_or(fields, "key")
            if key.length() > 0 {
              defs.push(
                pi_shortcut_def(
                  key,
                  pi_json_string_or(fields, "description"),
                  item,
                ),
              )
            }
          }
          _ => ()
        }
      }
    _ => ()
  }
  defs
}

///|
pub impl @posoco.CommandPort for PiCommandPort with fn commands(
  self : PiCommandPort,
) -> Array[@posoco.CommandDef] {
  self.defs()
}

///|
/// Project the bridge's raw {thrown, feedback, message} result onto a
/// CommandOutcome: string handler returns become Success feedback, handler
/// throws become Failure reasons.
fn pi_command_outcome(raw : Json) -> @posoco.CommandOutcome {
  match raw {
    Json::Object(fields) => {
      let thrown = match fields.get("thrown") {
        Some(Json::True) => true
        _ => false
      }
      let message = pi_json_string_or(fields, "message")
      if thrown {
        @posoco.CommandOutcome::Failure(
          reason=if message.length() > 0 {
            message
          } else {
            "pi command failed"
          },
        )
      } else {
        @posoco.CommandOutcome::Success(
          feedback=pi_json_string_or(fields, "feedback"),
          structured=None,
          ui_hint=Some(@posoco.UiHint::None),
        )
      }
    }
    _ => @posoco.CommandOutcome::Failure(reason="malformed pi command result")
  }
}

///|
pub impl @posoco.CommandPort for PiCommandPort with fn invoke(
  self : PiCommandPort,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  if !id.has_prefix("pi:") {
    return @posoco.CommandOutcome::Failure(
      reason="unknown pi command id: " + id,
    )
  }
  let name = id[3:].to_owned()
  let raw = wait_js_string(
    js_invoke_command_async(self.host, name, args.stringify()),
  ) catch {
    JsPromiseError::Rejected(message) =>
      raise @posoco.CommandError::ExecutionFailed(
        "pi command bridge rejected: " + message,
      )
  }
  pi_command_outcome(parse_json_or_null(raw))
}

///|
/// Serialize a CommandOutcome for the JS-facing invoke/export surface.
fn command_outcome_json(outcome : @posoco.CommandOutcome) -> Json {
  match outcome {
    Success(feedback~, structured~, ui_hint~) => {
      ignore(ui_hint)
      let fields : Array[(String, Json)] = [
        ("type", Json::string("success")),
        ("feedback", Json::string(feedback)),
      ]
      match structured {
        Some(value) => fields.push(("structured", value))
        None => ()
      }
      Json::object(Map::from_array(fields))
    }
    Failure(reason~) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("failure")),
          ("reason", Json::string(reason)),
        ]),
      )
    NeedsInput(prompt~) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("needs_input")),
          ("prompt", Json::string(prompt)),
        ]),
      )
  }
}
