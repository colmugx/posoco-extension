///|
/// `/statusbar` command: a read-only provider listing. The command takes
/// no arguments — layout customization and reorder moved to the segment
/// owners (each publisher decides its own priority when registering).

///|
fn listing_json(infos : Array[SegmentInfo]) -> Json {
  Json::array(
    infos.map(fn(info) {
      let fields : Array[(String, Json)] = [
        ("segment", Json::string(info.segment)),
        ("owner", Json::string(info.owner)),
        ("priority", Json::number(info.priority.to_double())),
      ]
      match info.label {
        Some(label) => fields.push(("label", Json::string(label)))
        None => ()
      }
      match info.color {
        Some(color) => fields.push(("color", Json::string(color)))
        None => ()
      }
      match info.value {
        Some(value) => fields.push(("value", Json::string(value)))
        None => ()
      }
      Json::object(Map::from_array(fields))
    }),
  )
}

///|
/// `/statusbar` accepts no arguments. Tolerate the "nothing after the
/// slash" spellings hosts produce (`null`, empty string, empty object,
/// empty `_positional`); anything else is a caller bug worth raising on.
fn expect_no_args(args : Json) -> Unit raise @posoco.CommandError {
  let empty = match args {
    Json::Null => true
    Json::String(raw) => raw.trim().to_owned().length() == 0
    Json::Object(fields) => {
      let mut empty = true
      for key, value in fields {
        let meaningful = match (key, value) {
          ("_positional", Json::String(raw)) =>
            raw.trim().to_owned().length() > 0
          _ => true
        }
        if meaningful {
          empty = false
        }
      }
      empty
    }
    _ => false
  }
  if !empty {
    raise @posoco.CommandError::InvalidArgs(
      reason="/statusbar takes no arguments",
    )
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
      description: "List the registered status bar segment providers",
      category: "ui",
      ctype: @posoco.CommandType::Action,
      params: [],
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
    "statusbar" => {
      expect_no_args(args)
      let infos = self.segments()
      let lines : Array[String] = ["statusbar segments: \{infos.length()}"]
      for info in infos {
        let color = match info.color {
          Some(color) => color
          None => "—"
        }
        let value = match info.value {
          Some(value) => value
          None => "—"
        }
        lines.push(
          "\{info.segment} | \{info.owner} | p\{info.priority} | \{color} | \{value}",
        )
      }
      @posoco.CommandOutcome::Success(
        feedback=lines.join("\n"),
        structured=Some(listing_json(infos)),
        ui_hint=Some(@posoco.UiHint::None),
      )
    }
    other => raise @posoco.CommandError::NotFound(other)
  }
}
