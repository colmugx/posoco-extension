///|
/// `/statusbar` command for the status bar extension.
///
/// With no arguments the command reports the current layout. With an ordered
/// segment list it customizes the bar (the codex `status_line` model);
/// `{"reset": true}` restores defaults. Setting an empty list hides the bar.

///|
priv enum StatusBarSelection {
  Query
  Reset
  SetItems(Array[String])
}

///|
/// Split a slash-style comma list ("model, tok") into trimmed segment ids.
fn split_items(raw : String) -> Array[String] {
  let items : Array[String] = []
  for part in raw.split(",") {
    let trimmed = part.trim().to_owned()
    if trimmed.length() > 0 {
      items.push(trimmed)
    }
  }
  items
}

///|
fn parse_items_array(
  entries : Array[Json],
) -> Array[String] raise @posoco.CommandError {
  let items : Array[String] = []
  for entry in entries {
    match entry {
      Json::String(value) =>
        if value.length() == 0 {
          raise @posoco.CommandError::InvalidArgs(
            reason="/statusbar items must be non-empty segment ids",
          )
        } else {
          items.push(value)
        }
      _ =>
        raise @posoco.CommandError::InvalidArgs(
          reason="/statusbar items must be an array of segment id strings",
        )
    }
  }
  items
}

///|
/// Parse `/statusbar` arguments. Accepts no arguments (query), a bare
/// comma-list string, `{items: [...]}`, the `_positional` string a host
/// slash parser produces, or `{reset: true}`.
fn statusbar_command_selection(
  args : Json,
) -> StatusBarSelection raise @posoco.CommandError {
  match args {
    Json::Null => Query
    Json::String(raw) =>
      if raw.length() == 0 {
        Query
      } else {
        SetItems(split_items(raw))
      }
    Json::Object(fields) => {
      let reset = match fields.get("reset") {
        None => false
        Some(Json::True) => true
        Some(Json::False) => false
        Some(_) =>
          raise @posoco.CommandError::InvalidArgs(
            reason="/statusbar reset must be a boolean",
          )
      }
      if reset {
        Reset
      } else {
        match fields.get("items") {
          Some(Json::Array(entries)) => SetItems(parse_items_array(entries))
          Some(Json::String(raw)) => SetItems(split_items(raw))
          Some(_) =>
            raise @posoco.CommandError::InvalidArgs(
              reason="/statusbar items must be an array of segment ids",
            )
          None =>
            match fields.get("_positional") {
              Some(Json::String(raw)) =>
                if raw.length() == 0 {
                  Query
                } else {
                  SetItems(split_items(raw))
                }
              Some(_) =>
                raise @posoco.CommandError::InvalidArgs(
                  reason="/statusbar expects segment ids",
                )
              None => Query
            }
        }
      }
    }
    _ =>
      raise @posoco.CommandError::InvalidArgs(
        reason="/statusbar expects no arguments, {items: [...]}, or {reset: true}",
      )
  }
}

///|
/// Layout validation: built-in segment ids plus any live custom segment
/// (a peer-published fact). A custom id that has no fact yet is rejected —
/// otherwise a typo would silently render nothing forever.
fn StatusBar::validate_layout(
  self : StatusBar,
  items : Array[String],
) -> Unit raise @posoco.CommandError {
  let known = available_segments()
  for item in self.custom_segments() {
    known.push(item)
  }
  for item in items {
    if !known.contains(item) {
      raise @posoco.CommandError::InvalidArgs(
        reason="unknown statusbar segment '\{item}'; available: \{known.join(", ")}",
      )
    }
  }
}

///|
pub impl @posoco.CommandPort for StatusBar with fn commands(_self : StatusBar) -> Array[
  @posoco.CommandDef,
] {
  [
    @posoco.CommandDef::{
      id: "statusbar",
      label: "Status Bar",
      description: "Show or customize the status bar segment layout",
      category: "ui",
      ctype: @posoco.CommandType::Input,
      params: [
        @posoco.CommandParam::{
          name: "items",
          label: "Segments",
          description: "Ordered segment ids; omit to show the current layout",
          ptype: @posoco.ParamType::Strs,
          required: false,
          default: None,
          choices: Some(available_segments()),
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
pub impl @posoco.CommandPort for StatusBar with fn invoke(
  self : StatusBar,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  match id {
    "statusbar" =>
      match statusbar_command_selection(args) {
        Query =>
          @posoco.CommandOutcome::Success(
            feedback="statusbar segments: \{self.items.join(" | ")}",
            structured=Some(self.layout_json()),
            ui_hint=Some(@posoco.UiHint::None),
          )
        Reset => {
          self.items = default_items()
          self.render()
          @posoco.CommandOutcome::Success(
            feedback="statusbar reset: \{self.items.join(" | ")}",
            structured=Some(self.layout_json()),
            ui_hint=Some(@posoco.UiHint::None),
          )
        }
        SetItems(items) => {
          self.validate_layout(items) catch {
            err =>
              return @posoco.CommandOutcome::Failure(reason=err.to_string())
          }
          self.items = items
          self.render()
          let feedback = if items.is_empty() {
            "statusbar hidden (no segments)"
          } else {
            "statusbar segments: \{items.join(" | ")}"
          }
          @posoco.CommandOutcome::Success(
            feedback~,
            structured=Some(self.layout_json()),
            ui_hint=Some(@posoco.UiHint::None),
          )
        }
      }
    other => raise @posoco.CommandError::NotFound(other)
  }
}
