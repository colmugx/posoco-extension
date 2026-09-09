///|
/// name_command.mbt — the /name command: rename the session this store last
/// persisted by writing the metadata `name` field on disk. The store carries
/// `current_id` so slash consumers need no explicit session argument.

///|
/// Rename a persisted session: load, set metadata `name`, save. Metadata
/// rides along the whole round-trip, so messages are untouched.
pub async fn JsonlSessionStore::set_session_name(
  self : JsonlSessionStore,
  id : String,
  name : String,
) -> Unit raise @posoco.SessionError {
  let session = self.load(id)
  session.metadata["name"] = Json::string(name)
  self.save(id, session)
}

///|
pub impl @posoco.CommandPort for JsonlSessionStore with fn commands(
  _self : JsonlSessionStore,
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
pub impl @posoco.CommandPort for JsonlSessionStore with fn invoke(
  self : JsonlSessionStore,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome {
  match id {
    "name" => {
      let outcome : @posoco.CommandOutcome = match self.current_id {
        None =>
          @posoco.CommandOutcome::Failure(
            reason="no active session in this store to rename",
          )
        Some(target) =>
          match command_positional_string(args) {
            None =>
              @posoco.CommandOutcome::Failure(reason="usage: /name <title>")
            Some(name) =>
              if name.trim(chars=" \t").length() == 0 {
                @posoco.CommandOutcome::Failure(
                  reason="usage: /name <non-empty title>",
                )
              } else {
                let renamed : Result[Unit, @posoco.SessionError] = Ok(
                  self.set_session_name(target, name),
                ) catch {
                  e => Err(e)
                }
                match renamed {
                  Ok(_) =>
                    @posoco.CommandOutcome::Success(
                      feedback="Session renamed to \"\{name}\"",
                      structured=None,
                      ui_hint=Some(@posoco.UiHint::None),
                    )
                  Err(e) =>
                    @posoco.CommandOutcome::Failure(
                      reason="rename failed: \{e}",
                    )
                }
              }
          }
      }
      outcome
    }
    other => @posoco.CommandOutcome::Failure(reason="unknown command: " + other)
  }
}

///|
/// Tolerant positional-argument extraction: slash frontends hand the raw
/// remainder as a JSON string, a `{value: ...}` object, or a one-element
/// array, depending on the host.
fn command_positional_string(args : Json) -> String? {
  match args {
    Json::String(s) => Some(s)
    Json::Object(map) =>
      match map.get("value") {
        Some(Json::String(s)) => Some(s)
        _ => None
      }
    Json::Array(items) =>
      match items.get(0) {
        Some(Json::String(s)) => Some(s)
        _ => None
      }
    _ => None
  }
}
