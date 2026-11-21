///|
/// request_responses.mbt — OpenAI Responses request shape for a custom
/// endpoint. Encoding of items, tools, and content blocks comes from
/// `posoco-kit-responses`; this file owns the request shape only:
///
/// - system turns lift out of the window into the leading developer message
///   inside the cacheable input prefix (the standing kit placement
///   contract; the top-level `instructions` field is reserved for
///   per-request guidance and cetas does not send it), and tools into
///   `tools` — each only when non-empty;
/// - the request is stateless (`store:false`) and replays the full window as
///   `input` on every call;
/// - a selected effort level becomes `reasoning.effort`; `off` sends no
///   reasoning surface at all. Level names are sent verbatim — no budget or
///   token count is invented for an endpoint whose scale is unknown;
/// - reasoning-capable requests drop temperature (OpenAI rejects it with 400).
///
/// Reasoning-item replay is not implemented on this wire: a generic endpoint
/// declares no encrypted-reasoning contract, so nothing is echoed back.

///|
fn responses_url(config : CustomConfig) -> String {
  config.base_url + config.endpoint_prefix + "/responses"
}

///|
/// Build the Responses request body.
fn build_responses_request(
  config : CustomConfig,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream~ : Bool = false,
) -> Json raise @posoco.ModelError {
  let shaped = shape_custom_images(
    @responses.fold_tool_attachments(messages, config.supports_images),
    config.supports_images,
  )
  let input : Array[Json] = []
  for msg in shaped {
    for item in @responses.message_to_responses_items(msg) {
      input.push(item)
    }
  }
  let history : Array[Json] = []
  let instructions : Array[String] = []
  for item in input {
    match item {
      Json::Object(fields) =>
        if fields.get("role") == Some(Json::string("system")) {
          instructions.push(
            @responses.message_item_text(provider="custom", fields),
          )
        } else {
          history.push(item)
        }
      _ => history.push(item)
    }
  }
  let joined = instructions.join("\n\n")
  let (history, instructions_field) = @responses.place_reusable_instructions(
    history, joined,
  )
  let effort : String? = config.reasoning_effort
  let fields : Array[(String, Json)] = [
    ("model", Json::string(config.model)),
    ("input", Json::array(history)),
    ("store", Json::boolean(false)),
  ]
  if stream {
    fields.push(("stream", Json::boolean(true)))
  }
  if instructions_field.length() > 0 {
    fields.push(("instructions", Json::string(instructions_field)))
  }
  if tools.length() > 0 {
    fields.push(
      (
        "tools",
        Json::array(tools.map(fn(t) { @responses.tool_to_responses_wire(t) })),
      ),
    )
  }
  match effort {
    // Reasoning requests reject temperature with 400; a selected level strips
    // it instead of failing the turn.
    Some(level) =>
      fields.push(
        (
          "reasoning",
          Json::object(Map::from_array([("effort", Json::string(level))])),
        ),
      )
    None =>
      match options.temperature {
        Some(t) => fields.push(("temperature", Json::number(t)))
        None => ()
      }
  }
  match options.max_output_tokens {
    Some(n) => fields.push(("max_output_tokens", Json::number(n.to_double())))
    None => ()
  }
  Json::object(Map::from_array(fields))
}
