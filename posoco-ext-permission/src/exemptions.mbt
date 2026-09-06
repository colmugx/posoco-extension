///|
/// The permission gate's own half of the `tool_exemptions` bus convention:
/// tools reported exempt by composed extensions skip this gate entirely.
/// A trust channel, not a security boundary — nothing at runtime verifies
/// that a report names only the reporter's own tools or that they are
/// safe; the guarantee is code review of the composed wiring.

///|
/// The topic string this gate honors exemption reports on; the payload is
/// `{"tools": [string, ...]}`, pinned by tests here and in the publisher.
let tool_exemptions_topic : String = "tool_exemptions"

///|
/// Decode an exemption-report payload. `None` when the data does not match
/// the convention (not an object, missing or non-array `tools`, non-string
/// entries) — the gate treats that as "nothing reported" and moves on.
fn parse_tool_exemptions(data : Json) -> Array[String]? {
  match data {
    Object(fields) =>
      match fields.get("tools") {
        Some(Array(entries)) => {
          let names : Array[String] = []
          for entry in entries {
            match entry {
              String(name) => names.push(name)
              _ => return None
            }
          }
          Some(names)
        }
        _ => None
      }
    _ => None
  }
}
