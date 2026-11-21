///|
/// Standing placement contract for reusable system content on the Responses
/// wire: it rides as the leading developer message inside the cacheable
/// input prefix, and the value for the top-level `instructions` field comes
/// back empty — the field is reserved for genuinely per-request guidance.
/// On GPT-6.2+ the backend appends that field after `input`, beyond every
/// cache breakpoint, and bills it as uncached input on every request (Nov
/// 2026 caching change), so reusable content must never use it. Placement
/// never guesses from the model id: unversioned and aliased ids take the
/// same shape, so a renamed deployment cannot silently fall back to
/// full-price input. Callers pass `eligible=false` only for backends with
/// their own fixed top-level contract or their own placement (Codex chatgpt
/// backend, Responses Lite shaping with derived ids).
pub fn place_reusable_instructions(
  input_items : Array[Json],
  instructions_text : String,
  eligible~ : Bool = true,
) -> (Array[Json], String) {
  if eligible && instructions_text.length() > 0 {
    let prefixed : Array[Json] = [
      developer_instructions_message(instructions_text),
    ]
    for item in input_items {
      prefixed.push(item)
    }
    (prefixed, "")
  } else {
    (input_items, instructions_text)
  }
}

///|
/// Leading developer message carrying base instructions inside the
/// cacheable input prefix. Shape mirrors the ordinary encoded message
/// items (role + content, no item id) so the placement stays a pure
/// re-carrier of the lifted system text.
pub fn developer_instructions_message(text : String) -> Json {
  Json::object(
    Map::from_array([
      ("role", Json::string("developer")),
      (
        "content",
        Json::array([
          Json::object(
            Map::from_array([
              ("type", Json::string("input_text")),
              ("text", Json::string(text)),
            ]),
          ),
        ]),
      ),
    ]),
  )
}
