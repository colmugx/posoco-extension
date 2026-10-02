///|
/// UUID-v5 prefix identity follows client.rs: thread namespace under OID,
/// then a payload-derived additional-tools/developer-message id.
fn openai_uuid_v5(ns_bytes : Bytes, payload : Bytes) -> Bytes {
  let digest = @crypto.sha1(ns_bytes + payload)
  let bytes = Array::make(16, b'\x00')
  for i in 0..<16 {
    bytes[i] = digest[i]
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x50
  bytes[8] = (bytes[8] & 0x3f) | 0x80
  Bytes::from_array(bytes)
}

///|
fn lite_prefix_id(
  session_id : String,
  prefix : String,
  payload : String,
) -> String {
  let oid = b"\x6b\xa7\xb8\x12\x9d\xad\x11\xd1\x80\xb4\x00\xc0\x4f\xd4\x30\xc8"
  let ns = openai_uuid_v5(oid, @utf8.encode(session_id))
  let id = openai_uuid_v5(ns, @utf8.encode(payload))
  prefix + "_" + (try! @uuid.from_bytes(id)).to_string()
}

///|
/// Canonical ToolDef contains ordinary function tools (no namespaces), so
/// use the official non-namespace tool conversion path for Responses Lite.
fn apply_responses_lite_shape(
  fields : Map[String, Json],
  session_id : String,
) -> Unit {
  let tools = match fields.get("tools") {
    Some(Json::Array(tools)) => tools
    _ => []
  }
  let instructions = match fields.get("instructions") {
    Some(Json::String(text)) => text
    _ => ""
  }
  let input = match fields.get("input") {
    Some(Json::Array(input)) => input
    _ => []
  }
  let prefix : Array[Json] = [
    Json::object(
      Map::from_array([
        ("type", Json::string("additional_tools")),
        (
          "id",
          Json::string(
            lite_prefix_id(session_id, "at", Json::array(tools).stringify()),
          ),
        ),
        ("role", Json::string("developer")),
        ("tools", Json::array(tools)),
      ]),
    ),
  ]
  if !instructions.is_empty() {
    prefix.push(
      Json::object(
        Map::from_array([
          ("type", Json::string("message")),
          ("id", Json::string(lite_prefix_id(session_id, "msg", instructions))),
          ("role", Json::string("developer")),
          (
            "content",
            Json::array([
              Json::object(
                Map::from_array([
                  ("type", Json::string("input_text")),
                  ("text", Json::string(instructions)),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    )
  }
  for item in input {
    prefix.push(item)
  }
  fields["input"] = Json::array(prefix)
  fields.remove("instructions")
  fields.remove("tools")
  fields["parallel_tool_calls"] = Json::boolean(false)
  let reasoning = match fields.get("reasoning") {
    Some(Json::Object(value)) => value
    _ => Map::from_array([])
  }
  reasoning["context"] = Json::string("all_turns")
  fields["reasoning"] = Json::object(reasoning)
}
