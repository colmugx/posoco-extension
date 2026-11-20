///|
fn hawdb_name_arg(args : Json) -> String? {
  match args {
    Json::String(text) => Some(text)
    Json::Object(fields) =>
      match fields.get("value") {
        Some(Json::String(text)) => Some(text)
        _ => None
      }
    Json::Array(items) =>
      match items.get(0) {
        Some(Json::String(text)) => Some(text)
        _ => None
      }
    _ => None
  }
}

///|
pub impl @posoco.CommandPort for HawdbSessionStore with fn commands(
  _self : HawdbSessionStore,
) -> Array[@posoco.CommandDef] {
  [
    @posoco.CommandDef::{
      id: "name",
      label: "Name session",
      description: "Rename the current session; the name shows up in session lists",
      category: "session",
      ctype: @posoco.CommandType::Input,
      params: [
        @posoco.CommandParam::{
          name: "value",
          label: "Title",
          description: "New display name for the current session",
          ptype: @posoco.ParamType::Str,
          required: true,
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
pub impl @posoco.CommandPort for HawdbSessionStore with fn invoke(
  self : HawdbSessionStore,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome {
  match id {
    "name" =>
      match self.current_id {
        None => @posoco.CommandOutcome::Failure(
          reason="no active session in this store to rename",
        )
        Some(target) =>
          match hawdb_name_arg(args) {
            None => @posoco.CommandOutcome::Failure(reason="usage: /name <title>")
            Some(name) =>
              if name.trim(chars=" \t").length() == 0 {
                @posoco.CommandOutcome::Failure(
                  reason="usage: /name <non-empty title>",
                )
              } else {
                let renamed : Result[Unit, @posoco.SessionError] = Ok(
                  self.set_session_name(target, name),
                ) catch {
                  error => Err(error)
                }
                match renamed {
                  Ok(_) => @posoco.CommandOutcome::Success(
                    feedback="Session renamed to \"\{name}\"",
                    structured=None,
                    ui_hint=Some(@posoco.UiHint::None),
                  )
                  Err(error) => @posoco.CommandOutcome::Failure(
                    reason="rename failed: \{error}",
                  )
                }
              }
          }
      }
    _ => @posoco.CommandOutcome::Failure(reason="unknown command: " + id)
  }
}

///|
pub extend HawdbSessionStore with @posoco.CommandPort::{invoke, commands}
