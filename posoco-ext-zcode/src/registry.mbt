///|
/// Build the `workspace/updateProviderRegistry` registry payload from the
/// `provider` map of `~/.zcode/v2/config.json`. Rules (zcode-acp
/// provider-registry + live probing against zcode 0.16.5):
/// - apiKey must be the `{"source":"inline","value":...}` union shape (a bare
///   string is rejected by the app-server)
/// - models must be an array (the v2 config stores a map)
/// - providers with zero models are skipped entirely (they reject the whole
///   payload)
/// - apiFormat: kind containing "anthropic" → "anthropic-messages", kind
///   containing "openai" → "openai-chat-completions", else omitted
/// - revision: FNV-1a 32-bit hex over the sorted concatenation of
///   "providerId|kind|baseURL|models-json" lines
///
/// Usability rule (proven live against zcode 3.11): the app-server's default
/// model lands on the first provider entry, and a provider whose v2 config
/// carries no inline api key cannot serve a turn ("Model provider is missing
/// an API key"). Such providers are skipped entirely, like zero-model ones;
/// providers are then emitted in lexicographic id order, so the first entry
/// is the alphabetically-first usable provider.
///
/// The payload carries api keys, so it stays plain Json — no typed struct,
/// no derives, nothing that encourages printing it.
pub fn zcode_build_registry(
  v2_config : Json,
  generated_at_ms~ : Int64,
) -> Result[Json, String] {
  match json_field(v2_config, "provider") {
    Some(Json::Object(provider_map)) => {
      let provider_ids : Array[String] = []
      for id, _entry in provider_map {
        provider_ids.push(id)
      }
      // Order matters: the app-server's default model lands on the first
      // provider entry, and this core's default String compare is
      // length-first, which would front-load short keyless ids. Emit in
      // lexicographic order — the proven probe's effective order.
      zcode_sort_lex(provider_ids)
      let elements : Array[Json] = []
      let lines : Array[String] = []
      for id in provider_ids {
        match zcode_provider_element(id, provider_map[id]) {
          Some((element, line)) => {
            elements.push(element)
            lines.push(line)
          }
          None => () // zero-model provider
        }
      }
      lines.sort()
      let mut concatenated = ""
      for line in lines {
        concatenated = concatenated + line + "\n"
      }
      Ok(
        Json::object(
          Map::from_array([
            ("providers", Json::array(elements)),
            ("generatedAt", Json::number(generated_at_ms.to_double())),
            ("revision", Json::string(zcode_fnv1a_hex(concatenated))),
          ]),
        ),
      )
    }
    _ => Err("zcode registry: v2 config has no 'provider' object")
  }
}

///|
/// True when a sorts after b in code-unit (lexicographic) order. The core
/// String compare is length-first, so the registry orders ids with this
/// instead of `.sort()`.
fn zcode_lex_gt(a : String, b : String) -> Bool {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let ca = a[i].to_int()
    let cb = b[i].to_int()
    if ca != cb {
      return ca > cb
    }
  }
  a.length() > b.length()
}

///|
/// In-place insertion sort by zcode_lex_gt (stable, deterministic).
fn zcode_sort_lex(ids : Array[String]) -> Unit {
  for i in 1..<ids.length() {
    let key = ids[i]
    let mut j = i - 1
    while j >= 0 && zcode_lex_gt(ids[j], key) {
      ids[j + 1] = ids[j]
      j = j - 1
    }
    ids[j + 1] = key
  }
}

///|
/// One provider element plus its revision signature line. None when the
/// provider has zero models or no usable inline api key — the app-server
/// defaults to the first entry, and a keyless entry only poisons that pick.
fn zcode_provider_element(
  provider_id : String,
  entry : Json,
) -> (Json, String)? {
  match entry {
    Json::Object(p) => {
      let options = match p.get("options") {
        Some(Json::Object(o)) => o
        _ => Map::from_array([])
      }
      match options.get("apiKey") {
        Some(Json::String(value)) => if value == "" { return None }
        Some(Json::Object(_)) => () // already union-shaped
        _ => return None
      }
      let models_map = match p.get("models") {
        Some(Json::Object(m)) => m
        _ => Map::from_array([])
      }
      if models_map.length() == 0 {
        return None
      }
      let kind = match p.get("kind") {
        Some(Json::String(s)) => Some(s)
        _ => None
      }
      let base_url = match options.get("baseURL") {
        Some(Json::String(s)) => Some(s)
        _ => None
      }
      let name = match p.get("name") {
        Some(Json::String(s)) => Some(s)
        _ => None
      }
      let source = match p.get("source") {
        Some(Json::String(s)) => s
        _ => "custom"
      }
      let (models, models_json) = zcode_models_array(models_map)
      let obj : Map[String, Json] = Map::from_array([
        ("providerId", Json::string(provider_id)),
        ("label", Json::string(name.unwrap_or(provider_id))),
        ("source", Json::string(source)),
        ("models", models),
      ])
      match kind {
        Some(k) => obj["kind"] = Json::string(k)
        None => ()
      }
      match zcode_api_format(kind) {
        Some(api_format) => obj["apiFormat"] = Json::string(api_format)
        None => ()
      }
      match base_url {
        Some(url) => obj["baseURL"] = Json::string(url)
        None => ()
      }
      match options.get("apiKey") {
        // An empty key is omitted: the app-server rejects inline values
        // shorter than one character.
        Some(Json::String(value)) =>
          if value != "" {
            obj["apiKey"] = Json::object(
              Map::from_array([
                ("source", Json::string("inline")),
                ("value", Json::string(value)),
              ]),
            )
          }
        Some(raw) =>
          match raw {
            // Already union-shaped (e.g. re-running over built output).
            Json::Object(_) => obj["apiKey"] = raw
            _ => ()
          }
        None => ()
      }
      match options.get("apiKeyRequired") {
        Some(flag) => obj["apiKeyRequired"] = flag
        None => ()
      }
      let kind_raw = kind.unwrap_or("")
      let base_raw = base_url.unwrap_or("")
      let line = "\{provider_id}|\{kind_raw}|\{base_raw}|\{models_json}"
      Some((Json::object(obj), line))
    }
    _ => None
  }
}

///|
/// Models as a deterministic, sorted array plus its canonical JSON text
/// (the signature input). Sorting matters: the v2 config stores a map and
/// map iteration order is not stable.
fn zcode_models_array(models_map : Map[String, Json]) -> (Json, String) {
  let model_ids : Array[String] = []
  for model_id, _entry in models_map {
    model_ids.push(model_id)
  }
  model_ids.sort()
  let models : Array[Json] = []
  for model_id in model_ids {
    models.push(zcode_model_element(model_id, models_map[model_id]))
  }
  let models_json = Json::array(models)
  (models_json, models_json.stringify())
}

///|
fn zcode_model_element(model_id : String, entry : Json) -> Json {
  let obj : Map[String, Json] = Map::from_array([
    ("modelId", Json::string(model_id)),
  ])
  match entry {
    Json::Object(m) => {
      match m.get("name") {
        Some(Json::String(label)) => obj["label"] = Json::string(label)
        _ => ()
      }
      match m.get("limit") {
        Some(Json::Object(limit)) => {
          match limit.get("context") {
            Some(Json::Number(n, ..)) => obj["contextWindow"] = Json::number(n)
            _ => ()
          }
          match limit.get("output") {
            Some(Json::Number(n, ..)) =>
              obj["maxOutputTokens"] = Json::number(n)
            _ => ()
          }
        }
        _ => ()
      }
      match m.get("reasoning") {
        Some(Json::Object(r)) => obj["reasoning"] = zcode_reasoning_element(r)
        _ => ()
      }
    }
    _ => ()
  }
  Json::object(obj)
}

///|
/// Reasoning block. Config `variants` may be bare strings or objects with a
/// (possibly labeled) "value"; output levels are always `{value, label}`.
fn zcode_reasoning_element(r : Map[String, Json]) -> Json {
  let enabled = match r.get("enabled") {
    // The core Json enum has no boolean variant: true/false are Json::True /
    // Json::False (Json::boolean(b) maps onto them).
    Some(Json::True) => true
    _ => false
  }
  let levels : Array[Json] = []
  match r.get("variants") {
    Some(Json::Array(variants)) =>
      for variant in variants {
        match variant {
          Json::String(value) =>
            levels.push(
              Json::object(
                Map::from_array([
                  ("value", Json::string(value)),
                  ("label", Json::string(value)),
                ]),
              ),
            )
          Json::Object(vo) =>
            match vo.get("value") {
              Some(Json::String(value)) => {
                let label = match vo.get("label") {
                  Some(Json::String(l)) => l
                  _ => value
                }
                levels.push(
                  Json::object(
                    Map::from_array([
                      ("value", Json::string(value)),
                      ("label", Json::string(label)),
                    ]),
                  ),
                )
              }
              _ => ()
            }
          _ => ()
        }
      }
    _ => ()
  }
  let obj : Map[String, Json] = Map::from_array([
    ("enabled", Json::boolean(enabled)),
    ("levels", Json::array(levels)),
  ])
  match r.get("defaultVariant") {
    Some(Json::String(default_level)) =>
      obj["defaultLevel"] = Json::string(default_level)
    _ => ()
  }
  Json::object(obj)
}

///|
fn zcode_api_format(kind : String?) -> String? {
  match kind {
    Some(k) =>
      if k.contains("anthropic") {
        Some("anthropic-messages")
      } else if k.contains("openai") {
        Some("openai-chat-completions")
      } else {
        None
      }
    None => None
  }
}

///|
/// FNV-1a 32-bit over chars, as 8 lowercase hex digits. MoonBit Int is
/// 32-bit two's complement, so the multiply wraps natively and masking the
/// low nibble of a shifted negative Int still yields the right hex digit.
fn zcode_fnv1a_hex(input : String) -> String {
  let mut h = 0x811c9dc5
  for ch in input {
    h = h ^ ch.to_int()
    h = h * 0x01000193
  }
  let buf = StringBuilder()
  for shift in [28, 24, 20, 16, 12, 8, 4, 0] {
    let nibble = (h >> shift) & 0xF
    if nibble < 10 {
      buf.write_string(nibble.to_string())
    } else {
      buf.write_char((nibble + 87).unsafe_to_char())
    }
  }
  buf.to_string()
}
