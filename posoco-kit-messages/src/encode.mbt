///|
/// encode.mbt — canonical Posoco transcript -> Messages request wire JSON.
///
/// Pure codec: no credentials, no transport, no retry policy. The calling
/// extension owns HTTP, authentication, pooling, cancellation, and retry.
///
/// Encoding invariants:
/// - System instructions ride the top-level `system` field (block array so
///   `cache_control` is expressible); a `SystemMessage` inside the transcript
///   is a typed error rather than a fabricated `system`-role wire message.
/// - `ToolMessage` becomes a `user` message carrying a `tool_result` block
///   correlated by `tool_use_id` — never a fabricated `tool` role.
/// - Tool-call ids pass through verbatim; no id is rewritten or inferred.
/// - Unsupported conversions (images in system/assistant position, empty
///   content, foreign thinking replay state) are typed errors — content is
///   never silently dropped.

///|
/// Prompt-cache placement marker. The wire shape is
/// `{"type": "ephemeral"}` with an optional lifetime; `ttl` accepts the
/// documented lifetimes ("5m", "1h") and rejects anything else so a typo
/// becomes a local error instead of a remote 400.
pub(all) struct CacheControl {
  ttl : String?
} derive(Eq, Debug)

///|
pub extend CacheControl with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend CacheControl with Eq::{not_equal, equal}

///|
/// Render the cache_control wire object.
pub fn CacheControl::to_wire(self : CacheControl) -> Json raise @posoco.ModelError {
  let fields : Array[(String, Json)] = [("type", Json::string("ephemeral"))]
  match self.ttl {
    Some(ttl) =>
      if ttl == "5m" || ttl == "1h" {
        fields.push(("ttl", Json::string(ttl)))
      } else {
        raise @posoco.ModelError::RequestBuild(
          "messages cache_control ttl must be \"5m\" or \"1h\" (stage=encode, category=ttl)",
        )
      }
    None => ()
  }
  Json::object(Map::from_array(fields))
}

///|
/// Attach a cache_control marker to one already-encoded content block
/// (documented placements: system blocks, user text/image blocks,
/// tool_result blocks, tool definitions). The block must be a JSON object;
/// an existing cache_control is replaced.
pub fn attach_cache_control(
  block : Json,
  cache_control~ : CacheControl,
) -> Json raise @posoco.ModelError {
  let wire = cache_control.to_wire()
  match block {
    Json::Object(fields) => {
      // Do not mutate the caller's block (Json objects can share a Map).
      let copied : Map[String, Json] = Map::from_array([])
      for entry in fields {
        let (key, value) = entry
        copied[key] = value
      }
      copied["cache_control"] = wire
      Json::object(copied)
    }
    _ =>
      raise @posoco.ModelError::RequestBuild(
        "messages cache_control applies to content blocks (stage=encode, category=not_object)",
      )
  }
}

///|
/// Tool-choice configuration: `auto` / `any` (must use a tool) / `none` /
/// a forced specific tool.
pub(all) enum MessagesToolChoice {
  Auto
  Any
  /// Wire type `none`: the model may not use tools. (Named `Forbid` so the
  /// variant never collides with `Option::None` in JSON literals.)
  Forbid
  Tool(name~ : String)
} derive(Eq, Debug)

///|
pub extend MessagesToolChoice with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend MessagesToolChoice with Eq::{not_equal, equal}

///|
fn MessagesToolChoice::to_wire(
  self : MessagesToolChoice,
) -> Json raise @posoco.ModelError {
  match self {
    Auto => Json::object({ "type": Json::string("auto") })
    Any => Json::object({ "type": Json::string("any") })
    Forbid => Json::object({ "type": Json::string("none") })
    Tool(name~) =>
      if name == "" {
        raise @posoco.ModelError::RequestBuild(
          "messages tool_choice tool name must be non-empty (stage=encode, category=tool_choice)",
        )
      } else {
        Json::object({
          "type": Json::string("tool"),
          "name": Json::string(name),
        })
      }
  }
}

///|
/// Extended-thinking configuration. `budget_tokens` must be at least 1024
/// per the protocol.
pub(all) enum ThinkingConfig {
  Enabled(budget_tokens~ : Int32)
  Adaptive
  BetweenTools
  Disabled
} derive(Eq, Debug)

///|
pub extend ThinkingConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ThinkingConfig with Eq::{not_equal, equal}

///|
fn ThinkingConfig::to_wire(
  self : ThinkingConfig,
) -> Json raise @posoco.ModelError {
  match self {
    Enabled(budget_tokens~) =>
      if budget_tokens < 1024 {
        raise @posoco.ModelError::RequestBuild(
          "messages thinking budget_tokens must be >= 1024 (stage=encode, category=thinking)",
        )
      } else {
        Json::object({
          "type": Json::string("enabled"),
          "budget_tokens": Json::number(budget_tokens.to_double()),
        })
      }
    Adaptive => Json::object({ "type": Json::string("adaptive") })
    BetweenTools => Json::object({ "type": Json::string("between_tools") })
    Disabled => Json::object({ "type": Json::string("disabled") })
  }
}

///|
/// Protocol-specific request settings. Deliberately separate from the
/// canonical `ChatOptions` (which only carries what every provider shares):
/// vendor tuning never leaks into the common type.
pub(all) struct MessagesRequestOptions {
  temperature : Double?
  stop_sequences : Array[String]
  tool_choice : MessagesToolChoice?
  thinking : ThinkingConfig?
  /// Opaque request `metadata` object (e.g. user id), passed through.
  metadata : Json?
  /// Explicit pass-through for future protocol fields the kit does not
  /// interpret (beta features belong to the caller's responsibility, e.g.
  /// via headers). Entries must be non-empty names; values are emitted
  /// verbatim at the top level. Documented as opaque: the kit does not
  /// validate their semantics.
  extra_top_level : Array[(String, Json)]
} derive(Debug)

///|
pub fn MessagesRequestOptions::MessagesRequestOptions(
  temperature? : Double? = None,
  stop_sequences? : Array[String] = [],
  tool_choice? : MessagesToolChoice? = None,
  thinking? : ThinkingConfig? = None,
  metadata? : Json? = None,
  extra_top_level? : Array[(String, Json)] = [],
) -> MessagesRequestOptions {
  {
    temperature,
    stop_sequences,
    tool_choice,
    thinking,
    metadata,
    extra_top_level,
  }
}

///|
/// Supported image media types for Messages input.
fn supported_image_media_type(media_type : String) -> Bool {
  ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(media_type)
}

///|
/// Encode one canonical Content item as a user-side content block.
/// http(s) data is treated as a URL source; anything else is base64 with
/// its declared media type. Unsupported media types are typed errors —
/// never dropped.
fn user_content_block(c : @posoco.Content) -> Json raise @posoco.ModelError {
  match c {
    @posoco.Content::Text(text) =>
      Json::object({
        "type": Json::string("text"),
        "text": Json::string(text),
      })
    @posoco.Content::Image(media_type~, data~) =>
      if !supported_image_media_type(media_type) {
        raise @posoco.ModelError::RequestBuild(
          "messages image media_type is not supported (stage=encode, category=media_type)",
        )
      } else if data.starts_with("http://") || data.starts_with("https://") {
        Json::object({
          "type": Json::string("image"),
          "source": Json::object({
            "type": Json::string("url"),
            "url": Json::string(data),
          }),
        })
      } else {
        Json::object({
          "type": Json::string("image"),
          "source": Json::object({
            "type": Json::string("base64"),
            "media_type": Json::string(media_type),
            "data": Json::string(data),
          }),
        })
      }
  }
}

///|
fn push_content_blocks(
  out~ : Array[Json],
  content~ : Array[@posoco.Content],
) -> Unit raise @posoco.ModelError {
  for block in content {
    match user_content_block(block) {
      Json::Null => ()
      encoded => out.push(encoded)
    }
  }
}

///|
/// Tool-result content: the text payload plus any attachments as sibling
/// blocks (the tool_result `content` field accepts both shapes).
fn tool_result_content(
  text~ : String,
  attachments~ : Array[@posoco.Content],
) -> Json raise @posoco.ModelError {
  if attachments.is_empty() {
    Json::string(text)
  } else {
    let blocks : Array[Json] = []
    if text != "" {
      blocks.push(
        Json::object({ "type": Json::string("text"), "text": Json::string(text) }),
      )
    }
    push_content_blocks(out=blocks, content=attachments)
    if blocks.is_empty() {
      raise @posoco.ModelError::RequestBuild(
        "messages tool_result with attachments must carry content (stage=encode, category=empty)",
      )
    }
    Json::array(blocks)
  }
}

///|
fn tool_result_block(
  call_id~ : String,
  text~ : String,
  structured~ : Json?,
  attachments~ : Array[@posoco.Content],
  is_error~ : Bool,
) -> Json raise @posoco.ModelError {
  if call_id == "" {
    raise @posoco.ModelError::RequestBuild(
      "messages tool_result requires the original tool_use id (stage=encode, category=tool_use_id)",
    )
  }
  let fields : Array[(String, Json)] = [
    ("type", Json::string("tool_result")),
    ("tool_use_id", Json::string(call_id)),
  ]
  // Structured payloads have no Messages wire placement; the text payload is
  // authoritative for the model (same rule the other kits apply).
  let _ = structured
  fields.push(("content", tool_result_content(text~, attachments~)))
  if is_error {
    fields.push(("is_error", Json::boolean(true)))
  }
  Json::object(Map::from_array(fields))
}

///|
/// Encode one transcript message into zero-or-more wire messages.
///
/// - `SystemMessage` is rejected: system content belongs in
///   `system_to_wire`, and a mid-transcript system message has no Messages
///   placement.
/// - `ToolMessage` becomes a `user` message with a correlated
///   `tool_result` block; error/failure outcomes set wire `is_error`.
/// - `AssistantMessage` replays thinking-family state first (from this
///   kit's `Reasoning.raw` envelope, fingerprint-verified), then visible
///   text, then `tool_use` blocks — the protocol's required ordering.
pub fn message_to_wire(msg : @posoco.Message) -> Array[Json] raise @posoco.ModelError {
  match msg {
    @posoco.Message::SystemMessage(..) =>
      raise @posoco.ModelError::RequestBuild(
        "system content must be encoded via system_to_wire, not as a transcript message (stage=encode, category=system_role)",
      )
    @posoco.Message::UserMessage(content~) => {
      let blocks : Array[Json] = []
      push_content_blocks(out=blocks, content~)
      if blocks.is_empty() {
        raise @posoco.ModelError::RequestBuild(
          "messages user message must carry content (stage=encode, category=empty)",
        )
      }
      [
        Json::object({
          "role": Json::string("user"),
          "content": Json::array(blocks),
        }),
      ]
    }
    @posoco.Message::AssistantMessage(content~, tool_calls~, reasoning~, ..) => {
      let blocks : Array[Json] = []
      let mut has_full_replay = false
      match reasoning {
        Some(reasoning) =>
          // Replay only this kit's own fingerprint-verified envelope. Plain
          // reasoning text without replay state is readable to the model
          // as-is (signatures only exist when this kit captured the turn —
          // documented safe conversion), and foreign codecs' raw state is
          // not ours to replay; their own codec owns it.
          match reasoning.raw {
            Some(raw) =>
              if is_messages_replay_envelope(Some(raw)) {
                for block in parse_replay_envelope(
                      provider="messages",
                      raw,
                      content~,
                      tool_calls~,
                    ) {
                  blocks.push(block)
                }
                has_full_replay = is_complete_messages_replay_envelope(raw)
              } else {
                raise @posoco.ModelError::RequestBuild(
                  "messages cannot replay foreign or malformed reasoning state (stage=encode, category=foreign_replay)",
                )
              }
            None => ()
          }
        None => ()
      }
      if !has_full_replay {
        for block in content {
          match block {
            @posoco.Content::Text(text) =>
            if text != "" {
              blocks.push(
                Json::object({
                  "type": Json::string("text"),
                  "text": Json::string(text),
                }),
              )
            }
            @posoco.Content::Image(..) =>
              raise @posoco.ModelError::RequestBuild(
                "messages assistant content cannot carry images (stage=encode, category=assistant_image)",
              )
          }
        }
        for tc in tool_calls {
          if tc.call_id.to_string() == "" || tc.name.to_string() == "" {
            raise @posoco.ModelError::RequestBuild(
              "messages tool_use id and name must be non-empty (stage=encode, category=tool_identity)",
            )
          }
          match tc.arguments {
            Json::Object(_) => ()
            _ =>
              raise @posoco.ModelError::RequestBuild(
                "messages tool_use input must be an object (stage=encode, category=tool_input)",
              )
          }
          blocks.push(
            Json::object({
              "type": Json::string("tool_use"),
              "id": Json::string(tc.call_id.to_string()),
              "name": Json::string(tc.name.to_string()),
              "input": tc.arguments,
            }),
          )
        }
      }
      if blocks.is_empty() {
        raise @posoco.ModelError::RequestBuild(
          "messages assistant message must carry content (stage=encode, category=empty)",
        )
      }
      [
        Json::object({
          "role": Json::string("assistant"),
          "content": Json::array(blocks),
        }),
      ]
    }
    @posoco.Message::ToolMessage(call_id~, outcome~, ..) => {
      let (text, attachments, is_error) = match outcome {
        @posoco.ToolOutcome::Success(content~, ..) => (content, [], false)
        @posoco.ToolOutcome::SuccessWithAttachments(content~, attachments~, ..) =>
          (content, attachments, false)
        @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
          (content, [], true)
        @posoco.ToolOutcome::RuntimeFailure(message~, ..) => (message, [], true)
        @posoco.ToolOutcome::NotExecuted(reason~, ..) =>
          (reason.to_string(), [], true)
      }
      [
        Json::object({
          "role": Json::string("user"),
          "content": Json::array([
            tool_result_block(
              call_id=call_id.to_string(),
              text~,
              structured=None,
              attachments~,
              is_error~,
            ),
          ]),
        }),
      ]
    }
  }
}

///|
/// Encode top-level system instructions as a block array (so
/// `cache_control` is expressible). Images are a typed error — the system
/// field is text-only.
pub fn system_to_wire(
  content~ : Array[@posoco.Content],
  cache_control~ : CacheControl? = None,
) -> Json raise @posoco.ModelError {
  let blocks : Array[Json] = []
  for block in content {
    match block {
      @posoco.Content::Text(text) =>
        if text != "" {
          blocks.push(
            Json::object({
              "type": Json::string("text"),
              "text": Json::string(text),
            }),
          )
        }
      @posoco.Content::Image(..) =>
        raise @posoco.ModelError::RequestBuild(
          "messages system content is text-only (stage=encode, category=system_image)",
        )
    }
  }
  if blocks.is_empty() {
    raise @posoco.ModelError::RequestBuild(
      "messages system content must be non-empty (stage=encode, category=empty)",
    )
  }
  match cache_control {
    // Protocol placement: cache_control rides the LAST system block.
    Some(cc) => {
      let last = blocks.length() - 1
      blocks[last] = attach_cache_control(blocks[last], cache_control=cc)
    }
    None => ()
  }
  Json::array(blocks)
}

///|
/// Encode one tool definition: name, description, and the JSON input schema.
pub fn tool_to_wire(
  tool~ : @posoco.ToolDef,
  cache_control~ : CacheControl? = None,
) -> Json raise @posoco.ModelError {
  if tool.name.to_string() == "" {
    raise @posoco.ModelError::RequestBuild(
      "messages tool name must be non-empty (stage=encode, category=tool_name)",
    )
  }
  let fields : Array[(String, Json)] = [
    ("name", Json::string(tool.name.to_string())),
    ("description", Json::string(tool.description)),
    ("input_schema", tool.input_schema),
  ]
  match cache_control {
    Some(cc) => fields.push(("cache_control", cc.to_wire()))
    None => ()
  }
  Json::object(Map::from_array(fields))
}

///|
/// Assemble the complete request body.
///
/// `max_tokens` is protocol-required and passed explicitly; `model` is the
/// caller's selection (the kit owns no model state). Validation performed
/// here keeps obviously-invalid combinations local: thinking conflicts with
/// a forced tool choice, thinking forces temperature 1.0, stop sequences are
/// bounded by the protocol (4) and must be non-empty strings.
pub fn encode_request(
  model~ : String,
  max_tokens~ : Int32,
  system~ : Json? = None,
  messages~ : Array[Json],
  tools~ : Array[Json] = [],
  options~ : MessagesRequestOptions = MessagesRequestOptions::MessagesRequestOptions(),
) -> Json raise @posoco.ModelError {
  if model == "" {
    raise @posoco.ModelError::RequestBuild(
      "messages request model must be non-empty (stage=encode, category=model)",
    )
  }
  if max_tokens <= 0 {
    raise @posoco.ModelError::RequestBuild(
      "messages max_tokens must be positive (stage=encode, category=max_tokens)",
    )
  }
  if messages.is_empty() {
    raise @posoco.ModelError::RequestBuild(
      "messages request must carry at least one message (stage=encode, category=empty)",
    )
  }
  match options.thinking {
    Some(Enabled(budget_tokens~)) => {
      if budget_tokens >= max_tokens {
        raise @posoco.ModelError::RequestBuild(
          "messages thinking budget_tokens must be smaller than max_tokens (stage=encode, category=thinking_budget)",
        )
      }
      let bad_temperature = match options.temperature {
        Some(t) => t != 1.0
        None => false
      }
      if bad_temperature {
        raise @posoco.ModelError::RequestBuild(
          "messages thinking requires temperature 1.0 or unset (stage=encode, category=temperature)",
        )
      }
      match options.tool_choice {
        Some(Any) | Some(Tool(..)) =>
          raise @posoco.ModelError::RequestBuild(
            "messages thinking is incompatible with a forced tool_choice (stage=encode, category=tool_choice)",
          )
        Some(Auto) | Some(Forbid) | None => ()
      }
    }
    Some(Adaptive) | Some(BetweenTools) | Some(Disabled) | None => ()
  }
  if options.stop_sequences.length() > 4 {
    raise @posoco.ModelError::RequestBuild(
      "messages stop_sequences accepts at most 4 entries (stage=encode, category=stop_sequences)",
    )
  }
  for seq in options.stop_sequences {
    if seq == "" {
      raise @posoco.ModelError::RequestBuild(
        "messages stop_sequences entries must be non-empty (stage=encode, category=stop_sequences)",
      )
    }
  }
  let fields : Array[(String, Json)] = [
    ("model", Json::string(model)),
    ("max_tokens", Json::number(max_tokens.to_double())),
  ]
  match system {
    Some(system) => fields.push(("system", system))
    None => ()
  }
  fields.push(("messages", Json::array(messages.copy())))
  if !tools.is_empty() {
    fields.push(("tools", Json::array(tools.copy())))
  }
  match options.tool_choice {
    Some(choice) => fields.push(("tool_choice", choice.to_wire()))
    None => ()
  }
  if !options.stop_sequences.is_empty() {
    fields.push((
      "stop_sequences",
      Json::array(options.stop_sequences.map(Json::string)),
    ))
  }
  match options.temperature {
    Some(t) => fields.push(("temperature", Json::number(t)))
    None => ()
  }
  match options.thinking {
    Some(config) => fields.push(("thinking", config.to_wire()))
    None => ()
  }
  match options.metadata {
    Some(metadata) => fields.push(("metadata", metadata))
    None => ()
  }
  for entry in options.extra_top_level {
    let (name, value) = entry
    if name == "" {
      raise @posoco.ModelError::RequestBuild(
        "messages extra_top_level names must be non-empty (stage=encode, category=extra)",
      )
    }
    if [
      "model", "max_tokens", "system", "messages", "tools", "tool_choice",
      "stop_sequences", "temperature", "thinking", "metadata",
    ].contains(name) {
      raise @posoco.ModelError::RequestBuild(
        "messages extra_top_level cannot override core fields (stage=encode, category=reserved)",
      )
    }
    fields.push((name, value))
  }
  Json::object(Map::from_array(fields))
}
