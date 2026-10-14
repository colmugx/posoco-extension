///|
/// decode.mbt — Messages response wire JSON -> canonical Posoco completion.
///
/// Pure codec with deterministic, bounded diagnostics: parse errors carry
/// the failing stage and a category, never payload contents. Thinking-family
/// blocks are captured into this kit's replay envelope; opaque future block
/// types ride the envelope for transcript continuity without being
/// interpreted.

///|
/// Protocol stop reasons mapped onto canonical finish reasons:
///
/// - `end_turn`      -> Stop
/// - `stop_sequence` -> Stop (generation ended cleanly at a user sequence;
///    the raw value stays available on `MessagesResult.stop_reason`)
/// - `tool_use`      -> ToolCalls
/// - `max_tokens`    -> Length
/// - anything else   -> `Other(raw)` — unknown values are preserved, never
///    collapsed into Stop.
pub fn map_stop_reason(
  reason~ : String,
) -> @posoco.FinishReason raise @posoco.ModelError {
  match reason {
    "end_turn" | "stop_sequence" => Stop
    "tool_use" => ToolCalls
    "max_tokens" => Length
    "" =>
      raise @posoco.ModelError::ResponseParse(
        "messages response parse failure (stage=stop_reason, category=empty)",
      )
    other => Other(other)
  }
}

///|
/// Non-streaming response facts the canonical fields cannot carry:
/// the raw stop reason, the message id / model echo, the native usage
/// counters, and opaque top-level extension fields (documented pass-through
/// for future protocol fields; the kit does not interpret them).
pub(all) struct MessagesResult {
  completion : @posoco.Completion
  stop_reason : String
  stop_sequence : String?
  response_id : String
  model : String
  usage : MessagesUsage?
  cache_creation : MessagesCacheCreation?
  extensions : Array[(String, Json)]
} derive(Debug)

///|
pub extend MessagesResult with Debug::{to_repr}

///|
/// Top-level fields this kit interprets; everything else is surfaced via
/// `MessagesResult.extensions` verbatim.
fn known_top_level_field(name : String) -> Bool {
  [
    "id", "type", "role", "model", "content", "stop_reason", "stop_sequence", "usage",
  ].contains(name)
}

///|
fn wire_string_field(
  provider~ : String,
  fields : Map[String, Json],
  key~ : String,
  required~ : Bool,
) -> String? raise @posoco.ModelError {
  match fields.get(key) {
    Some(Json::String(s)) => Some(s)
    Some(Json::Null) | None =>
      if required {
        raise @posoco.ModelError::ResponseParse(
          "\{provider} response parse failure (stage=\{key}, category=missing)",
        )
      } else {
        None
      }
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} response parse failure (stage=\{key}, category=wrong_type)",
      )
  }
}

///|
/// Tool arguments tolerance: the protocol types `input` as an object and
/// content_block_start carries an empty `{}` placeholder, so an absent or
/// explicit-null input is the documented empty-arguments shape. Any other
/// non-object shape is a typed error, never silently coerced.
fn tool_use_arguments(
  provider~ : String,
  fields : Map[String, Json],
) -> Json raise @posoco.ModelError {
  match fields.get("input") {
    Some(Json::Object(_)) => fields.get("input").unwrap_or(Json::object({}))
    Some(Json::Null) | None => Json::object({})
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} response parse failure (stage=tool.input, category=wrong_type)",
      )
  }
}

///|
/// One decoded assistant content block: either canonical payload or replay
/// state. Tool calls surface through `tool_calls`.
priv enum DecodedBlock {
  Text(String)
  ToolCall(@posoco.ToolCall)
  Replay(Json)
}

///|
fn decode_content_block(
  provider~ : String,
  block : Json,
) -> DecodedBlock raise @posoco.ModelError {
  let fields = match block {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} response parse failure (stage=content_block, category=not_object)",
      )
  }
  let kind = match fields.get("type") {
    Some(Json::String(kind)) if kind != "" => kind
    Some(Json::String(_)) | Some(_) | None =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} response parse failure (stage=content_block.type, category=missing)",
      )
  }
  match kind {
    "text" =>
      match fields.get("text") {
        Some(Json::String(text)) => DecodedBlock::Text(text)
        Some(Json::Null) | None =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} response parse failure (stage=text, category=missing)",
          )
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} response parse failure (stage=text, category=wrong_type)",
          )
      }
    "tool_use" => {
      let id = match
        wire_string_field(provider~, fields, key="id", required=true) {
        Some(id) =>
          if id == "" {
            raise @posoco.ModelError::ResponseParse(
              "\{provider} response parse failure (stage=tool.id, category=empty)",
            )
          } else {
            id
          }
        None =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} response parse failure (stage=tool.id, category=missing)",
          )
      }
      let name = match
        wire_string_field(provider~, fields, key="name", required=true) {
        Some(name) =>
          if name == "" {
            raise @posoco.ModelError::ResponseParse(
              "\{provider} response parse failure (stage=tool.name, category=empty)",
            )
          } else {
            name
          }
        None =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} response parse failure (stage=tool.name, category=missing)",
          )
      }
      DecodedBlock::ToolCall({
        call_id: @posoco.CallId::unchecked(id),
        name: @posoco.ToolName::unchecked(name),
        arguments: tool_use_arguments(provider~, fields),
      })
    }
    // Thinking-family and unknown future blocks: preserved verbatim into the
    // replay envelope (signatures and redacted payloads never surface as
    // text). Validation happens in the envelope builder.
    _ => DecodedBlock::Replay(validated_replay_block(provider~, block))
  }
}

///|
/// Parse a complete non-streaming `message` object.
///
/// Handles text blocks, tool_use blocks (multiple calls, mixed ordering with
/// thinking blocks), thinking / signed thinking / redacted thinking replay
/// state, stop reasons, native usage counters, and opaque top-level
/// extension fields. Incomplete or malformed shapes are typed errors;
/// missing token counts never become fabricated numbers.
pub fn parse_response(
  provider~ : String,
  body : Json,
) -> MessagesResult raise @posoco.ModelError {
  let fields = match body {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} response parse failure (stage=response, category=not_object)",
      )
  }
  match fields.get("type") {
    Some(Json::String("message")) => ()
    Some(Json::String(_)) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} response parse failure (stage=type, category=unexpected)",
      )
    Some(_) | None =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} response parse failure (stage=type, category=missing)",
      )
  }
  match fields.get("role") {
    Some(Json::String("assistant")) => ()
    Some(Json::String(_)) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} response parse failure (stage=role, category=unexpected)",
      )
    Some(_) | None =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} response parse failure (stage=role, category=missing)",
      )
  }
  let response_id = match
    wire_string_field(provider~, fields, key="id", required=true) {
    Some(id) => id
    None => ""
  }
  let model = match
    wire_string_field(provider~, fields, key="model", required=true) {
    Some(model) => model
    None => ""
  }
  let content_blocks = match fields.get("content") {
    Some(Json::Array(blocks)) => blocks
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} response parse failure (stage=content, category=wrong_type)",
      )
    None =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} response parse failure (stage=content, category=missing)",
      )
  }
  let replay_blocks : Array[Json] = []
  let content : Array[@posoco.Content] = []
  let tool_calls : Array[@posoco.ToolCall] = []
  let thinking_text = StringBuilder()
  for block in content_blocks {
    match decode_content_block(provider~, block) {
      DecodedBlock::Text(text) =>
        if text != "" {
          content.push(@posoco.Content::Text(text))
        }
      DecodedBlock::ToolCall(tc) => tool_calls.push(tc)
      DecodedBlock::Replay(block) => {
        replay_blocks.push(block)
        // Canonical projection of thinking: the visible reasoning text.
        // Signatures/redacted payloads never surface here.
        match block {
          Json::Object(fields) =>
            match fields.get("thinking") {
              Some(Json::String(part)) => {
                thinking_text.write_string(part)
                // Protocol separates adjacent thinking blocks visually.
                thinking_text.write_string("\n\n")
              }
              Some(_) | None => ()
            }
          _ => ()
        }
      }
    }
  }
  let raw_stop_reason = match
    wire_string_field(provider~, fields, key="stop_reason", required=true) {
    Some(reason) => reason
    None => ""
  }
  let finish = map_stop_reason(reason=raw_stop_reason)
  let stop_sequence = wire_string_field(
    provider~,
    fields,
    key="stop_sequence",
    required=false,
  )
  let usage = match fields.get("usage") {
    Some(Json::Object(_)) =>
      Some(
        parse_messages_usage(
          provider~,
          fields.get("usage").unwrap_or(Json::null()),
        ),
      )
    Some(Json::Null) | None => None
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} response parse failure (stage=usage, category=wrong_type)",
      )
  }
  let cache_creation = match fields.get("usage") {
    Some(Json::Object(_)) =>
      Some(
        parse_messages_cache_creation(
          fields.get("usage").unwrap_or(Json::null()),
        ),
      )
    _ => None
  }
  let extensions : Array[(String, Json)] = []
  for entry in fields {
    let (name, value) = entry
    if !known_top_level_field(name) {
      extensions.push((name, value))
    }
  }
  let reasoning : @posoco.Reasoning? = if replay_blocks.is_empty() {
    None
  } else {
    Some({
      content: thinking_text.to_string(),
      raw: Some(
        build_replay_envelope(
          content~,
          tool_calls~,
          blocks=replay_blocks,
          full_blocks=Some(content_blocks),
        ),
      ),
    })
  }
  let completion = @posoco.Completion::Completion(
    content~,
    tool_calls~,
    reasoning~,
    finish_reason=finish,
    usage=match usage {
      Some(native) => Some(native.to_canonical())
      None => None
    },
  )
  {
    completion,
    stop_reason: raw_stop_reason,
    stop_sequence,
    response_id,
    model,
    usage,
    cache_creation,
    extensions,
  }
}
