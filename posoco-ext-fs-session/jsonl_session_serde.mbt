///|
/// jsonl_session_serde.mbt — Shared Session↔JSONL codec (target-agnostic).
///
/// Why manual codec: posoco's kernel `Message`/`Content`/`ToolCall` do NOT
/// implement `@json.ToJson`/`FromJson`. Rather than modify core types just for
/// this extension, we hand-roll a compact JSONL codec here.
///
/// Format (one JSON value per line):
///   line 1: metadata object — `{"k": <json>, ...}` (may be `{}` for empty)
///   line 2..: messages in order — each line is `{"role": ..., "content": [...], ...}`
///
/// Disk-format compatibility (M3.6/M3.7 migration):
/// The on-disk JSON shape is unchanged from the legacy `Role`+struct `Message`
/// era. The `role` field is still one of `"system" | "user" | "assistant" | "tool"`.
/// What changed is only the in-memory representation: `Message` is now a kernel
/// enum where the role is encoded in the variant tag (`UserMessage`,
/// `AssistantMessage`, etc.) instead of a separate `Role` field. This codec
/// maps between the two.
///
///   role="system"    ↔ Message::SystemMessage(content~)
///   role="user"      ↔ Message::UserMessage(content~)
///   role="assistant" ↔ Message::AssistantMessage(content~, tool_calls~,
///                       reasoning~, finish_reason~)
///   role="tool"      ↔ Message::ToolMessage(call_id~, tool_name~, outcome~)
///
/// For `ToolMessage`, the legacy fields map onto the new variant as:
///   - `tool_call_id` ↔ ToolMessage.call_id   (CallId)
///   - `name`         ↔ ToolMessage.tool_name (ToolName)
///   - `content[0]` text ↔ ToolMessage.outcome Success/ToolReportedError content
/// A round-trip preserves the role tag and these fields; the remaining
/// `finish_reason` is stored as a best-effort string when non-default.
///
/// Design constraints:
/// - Pure functions (no IO, no async). Parse failures are returned via
///   `Result[_, SessionError]` so the async SessionStore implementation can
///   raise the typed codec failure at its boundary.
/// - Output is deterministic so save→load round-trips are stable.
/// - Empty session serialises to a single metadata line.

///|
/// Serialise a `Content` enum to JSON.
/// - `Text(s)`  → `{"type": "text", "text": s}`
/// - `Image(media_type, data)` → `{"type": "image", "media_type": mt, "data": d}`
///
/// Note: kernel `Content::Image` carries `(media_type, data)`. The legacy disk
/// format used `(url, mime)`; we now write the kernel field names so the JSON
/// self-documents the kernel ADT. Reading accepts both shapes for tolerance.
fn content_to_json(content : @posoco.Content) -> Json {
  match content {
    @posoco.Content::Text(text) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("text")),
          ("text", Json::string(text)),
        ]),
      )
    @posoco.Content::Image(media_type~, data~) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("image")),
          ("media_type", Json::string(media_type)),
          ("data", Json::string(data)),
        ]),
      )
  }
}

///|
/// Parse a `Content` JSON back to `Content`. Returns `None` on shape mismatch.
/// Accepts both the new kernel shape (`media_type`/`data`) and the legacy
/// `url`/`mime` shape so older session files still load.
fn content_from_json(json : Json) -> @posoco.Content? {
  match json {
    Json::Object(map) =>
      if map.contains("type") {
        match map["type"] {
          Json::String(s) if s == "text" =>
            match map.get("text") {
              Some(Json::String(t)) => Some(@posoco.Content::Text(t))
              _ => None
            }
          Json::String(s) if s == "image" =>
            // New shape: media_type + data.
            match (map.get("media_type"), map.get("data")) {
              (Some(Json::String(mt)), Some(Json::String(d))) =>
                Some(@posoco.Content::Image(media_type=mt, data=d))
              _ =>
                // Legacy shape: url + mime. Map url→data, mime→media_type so
                // old files continue to load.
                match (map.get("url"), map.get("mime")) {
                  (Some(Json::String(url)), Some(Json::String(mime))) =>
                    Some(@posoco.Content::Image(media_type=mime, data=url))
                  _ => None
                }
            }
          _ => None
        }
      } else {
        None
      }
    _ => None
  }
}

///|
/// Serialise a `ToolCall` to JSON.
/// The disk key is `id` (legacy stable format); the kernel field is `call_id`.
/// `arguments` is already a `Json` so it is inserted verbatim.
fn tool_call_to_json(call : @posoco.ToolCall) -> Json {
  Json::object(
    Map::from_array([
      ("id", Json::string(call.call_id.to_string())),
      ("name", Json::string(call.name.to_string())),
      ("arguments", call.arguments),
    ]),
  )
}

///|
/// Parse a `ToolCall` JSON. Returns `None` on shape mismatch.
/// Accepts either `id` (legacy disk key) or `call_id` (kernel field name) so
/// files written by either naming scheme load.
fn tool_call_from_json(json : Json) -> @posoco.ToolCall? {
  match json {
    Json::Object(map) => {
      // Prefer the legacy `id` key if present, otherwise accept `call_id`.
      let id_str = match map.get("id") {
        Some(Json::String(s)) => Some(s)
        _ =>
          match map.get("call_id") {
            Some(Json::String(s)) => Some(s)
            _ => None
          }
      }
      let name_str = match map.get("name") {
        Some(Json::String(s)) => Some(s)
        _ => None
      }
      let arguments = map.get("arguments")
      match (id_str, name_str, arguments) {
        (Some(id), Some(name), Some(args)) =>
          Some(@posoco.ToolCall::{
            call_id: @posoco.CallId::unchecked(id),
            name: @posoco.ToolName::unchecked(name),
            arguments: args,
          })
        _ => None
      }
    }
    _ => None
  }
}

///|
/// Serialise a `Message` to JSON. All optional fields omitted when empty/None
/// to keep output compact and stable. The on-disk `role` string is derived
/// from the variant tag.
fn message_to_json(msg : @posoco.Message) -> Json {
  match msg {
    @posoco.Message::SystemMessage(content~) => {
      let base = Map::from_array([
        ("role", Json::string("system")),
        ("content", Json::array(content.map(content_to_json))),
      ])
      Json::object(base)
    }
    @posoco.Message::UserMessage(content~) => {
      let base = Map::from_array([
        ("role", Json::string("user")),
        ("content", Json::array(content.map(content_to_json))),
      ])
      Json::object(base)
    }
    @posoco.Message::AssistantMessage(
      content~,
      tool_calls~,
      reasoning~,
      finish_reason~
    ) => {
      let base = Map::from_array([
        ("role", Json::string("assistant")),
        ("content", Json::array(content.map(content_to_json))),
      ])
      // tool_calls: include only when non-empty (most messages don't carry them).
      if !tool_calls.is_empty() {
        base["tool_calls"] = Json::array(tool_calls.map(tool_call_to_json))
      }
      match reasoning {
        Some(r) => {
          base["reasoning_content"] = Json::string(r.content)
          // Provider-defined replay payload (e.g. OpenAI reasoning items);
          // persisted verbatim, absent on legacy files.
          match r.raw {
            Some(raw) => base["reasoning_raw"] = raw
            None => ()
          }
        }
        None => ()
      }
      // finish_reason: write when non-default so default Stop does not bloat
      // the on-disk shape. Legacy files had no finish_reason field; absent
      // means Stop on read.
      match finish_reason {
        @posoco.FinishReason::Stop => ()
        @posoco.FinishReason::Length =>
          base["finish_reason"] = Json::string("length")
        @posoco.FinishReason::ToolCalls =>
          base["finish_reason"] = Json::string("tool_calls")
        @posoco.FinishReason::Other(s) =>
          base["finish_reason"] = Json::string(s)
      }
      Json::object(base)
    }
    @posoco.Message::ToolMessage(call_id~, tool_name~, outcome~) => {
      // Map the new ToolMessage ADT back onto the legacy disk shape:
      //   tool_call_id ← call_id
      //   name         ← tool_name
      //   content[0]   ← outcome.content (for Success / ToolReportedError)
      // Other outcome variants serialise their summary as the text content so
      // the message is still human-readable on disk.
      let content_text = outcome_content_text(outcome)
      let base = Map::from_array([
        ("role", Json::string("tool")),
        (
          "content",
          Json::array([content_to_json(@posoco.Content::Text(content_text))]),
        ),
        ("tool_call_id", Json::string(call_id.to_string())),
        ("name", Json::string(tool_name.to_string())),
      ])
      Json::object(base)
    }
  }
}

///|
/// Extract a human-readable content string from a `ToolOutcome`. Used when
/// serialising `ToolMessage` to the legacy `content` field.
fn outcome_content_text(outcome : @posoco.ToolOutcome) -> String {
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) => content
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => content
    other => other.summary()
  }
}

///|
/// Parse an array of content JSONs. Returns `None` on any malformed item.
fn parse_content_array(arr : Array[Json]) -> Array[@posoco.Content]? {
  let result : Array[@posoco.Content] = []
  for item in arr {
    match content_from_json(item) {
      Some(c) => result.push(c)
      None => return None
    }
  }
  Some(result)
}

///|
/// Parse an array of tool-call JSONs. Returns `None` on any malformed item.
fn parse_tool_call_array(arr : Array[Json]) -> Array[@posoco.ToolCall]? {
  let result : Array[@posoco.ToolCall] = []
  for item in arr {
    match tool_call_from_json(item) {
      Some(c) => result.push(c)
      None => return None
    }
  }
  Some(result)
}

///|
/// Parse the `finish_reason` JSON value. Defaults to `Stop` when absent or
/// unrecognised — matching the legacy "no field" semantics.
fn finish_reason_from_json(json : Json?) -> @posoco.FinishReason {
  match json {
    None => @posoco.FinishReason::Stop
    Some(Json::String(s)) =>
      match s {
        "stop" => @posoco.FinishReason::Stop
        "length" => @posoco.FinishReason::Length
        "tool_calls" => @posoco.FinishReason::ToolCalls
        other => @posoco.FinishReason::Other(other)
      }
    _ => @posoco.FinishReason::Stop
  }
}

///|
/// Parse a `Message` JSON. Unknown optional fields are silently skipped;
/// missing required fields (`role`, `content`) or shape mismatches return `None`.
///
/// The role tag drives which `Message` variant is constructed. For
/// `assistant`, optional `tool_calls` / `reasoning_content` / `reasoning_raw`
/// / `finish_reason` are decoded. For `tool`, `tool_call_id` and `name` plus
/// the first content
/// text are mapped onto `ToolMessage(call_id, tool_name, outcome)`.
fn message_from_json(json : Json) -> @posoco.Message? {
  match json {
    Json::Object(map) =>
      if !map.contains("role") || !map.contains("content") {
        None
      } else {
        let role = match map["role"] {
          Json::String(s) => Some(s)
          _ => None
        }
        let content_arr = match map["content"] {
          Json::Array(arr) => parse_content_array(arr)
          _ => None
        }
        match (role, content_arr) {
          (Some(r), Some(content)) =>
            match r {
              "system" => Some(@posoco.Message::SystemMessage(content~))
              "user" => Some(@posoco.Message::UserMessage(content~))
              "assistant" => {
                let tool_calls : Array[@posoco.ToolCall] = match
                  map.get("tool_calls") {
                  Some(Json::Array(arr)) =>
                    match parse_tool_call_array(arr) {
                      Some(parsed) => parsed
                      None => return None
                    }
                  _ => []
                }
                let reasoning = match map.get("reasoning_content") {
                  Some(Json::String(s)) => {
                    // Provider replay payload rides along verbatim; absent on
                    // legacy files and for text-only reasoning providers.
                    let raw = map.get("reasoning_raw")
                    Some(@posoco.Reasoning::{ content: s, raw })
                  }
                  _ => None
                }
                let finish_reason = finish_reason_from_json(
                  map.get("finish_reason"),
                )
                Some(
                  @posoco.Message::AssistantMessage(
                    content~,
                    tool_calls~,
                    reasoning~,
                    finish_reason~,
                  ),
                )
              }
              "tool" => {
                // Map the legacy tool-message fields onto the new
                // ToolMessage(call_id, tool_name, outcome).
                let call_id_str = match map.get("tool_call_id") {
                  Some(Json::String(s)) => s
                  _ => return None
                }
                let tool_name_str = match map.get("name") {
                  Some(Json::String(s)) => s
                  _ => ""
                }
                // Best-effort content text for the outcome payload.
                let content_text = match content.get(0) {
                  Some(@posoco.Content::Text(t)) => t
                  _ => ""
                }
                let outcome = @posoco.ToolOutcome::Success(
                  content=content_text,
                  structured=None,
                )
                Some(
                  @posoco.Message::ToolMessage(
                    call_id=@posoco.CallId::unchecked(call_id_str),
                    tool_name=@posoco.ToolName::unchecked(tool_name_str),
                    outcome~,
                  ),
                )
              }
              _ => None
            }
          _ => None
        }
      }
    _ => None
  }
}

///|
/// Render a full `Session` to a JSONL string. Always non-empty (at minimum
/// one metadata line). Lines are joined by `\n` and the result ends with `\n`
/// so a truncate-rewrite is just one write call.
pub fn session_to_jsonl(session : @posoco.Session) -> String {
  let metadata_json = Json::object(session.metadata)
  let buf = StringBuilder::new()
  buf.write_string(metadata_json.stringify())
  for msg in session.messages {
    buf.write_char('\n')
    buf.write_string(message_to_json(msg).stringify())
  }
  buf.write_char('\n')
  buf.to_string()
}

///|
/// Parse a JSONL string back to a `Session`.
///
/// Rules:
/// - Empty / whitespace-only input → empty session (no error). This matches
///   SessionStore::load's "file does not exist → empty session" contract.
/// - First non-empty line must be the metadata object.
/// - Subsequent lines are parsed as messages; a malformed message aborts with
///   `Err(Load(...))` so the caller can surface the corruption loudly.
pub fn session_from_jsonl(
  content : String,
) -> Result[@posoco.Session, @posoco.SessionError] {
  // String::split returns Iter[StringView]; collect non-empty lines.
  let non_empty : Array[String] = []
  for line in content.split("\n") {
    let trimmed = line.trim(chars=" \t\r")
    if trimmed.length() > 0 {
      non_empty.push(line.to_owned())
    }
  }
  if non_empty.is_empty() {
    return Ok(@posoco.Session::{ messages: [], metadata: Map::from_array([]) })
  }
  // First non-empty line: metadata object. `@json.parse` raises ParseError.
  let metadata_parse : Result[Json, Error] = Ok(@json.parse(non_empty[0])) catch {
    e => Err(e)
  }
  let metadata : Map[String, Json] = match metadata_parse {
    Ok(Json::Object(m)) => m
    Ok(_) =>
      return Err(
        @posoco.SessionError::Load("jsonl: metadata line is not a JSON object"),
      )
    Err(e) =>
      return Err(
        @posoco.SessionError::Load("jsonl: failed to parse metadata line: \{e}"),
      )
  }
  let messages : Array[@posoco.Message] = []
  for i = 1; i < non_empty.length(); i = i + 1 {
    let line = non_empty[i]
    let json_parse : Result[Json, Error] = Ok(@json.parse(line)) catch {
      e => Err(e)
    }
    let json = match json_parse {
      Ok(j) => j
      Err(e) =>
        return Err(
          @posoco.SessionError::Load(
            "jsonl: failed to parse message line: \{e}",
          ),
        )
    }
    match message_from_json(json) {
      Some(msg) => messages.push(msg)
      None =>
        return Err(
          @posoco.SessionError::Load(
            "jsonl: malformed message at line \{i + 1}",
          ),
        )
    }
  }
  Ok(@posoco.Session::{ messages, metadata })
}

///|
/// Compute the file path for a session id under a root directory.
/// The id is used verbatim as the filename stem (caller is responsible for
/// sanitising; this is intentionally simple — no path escaping).
pub fn jsonl_session_path(root_dir : String, id : String) -> String {
  "\{root_dir}/\{id}.jsonl"
}
