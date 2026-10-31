///|
/// request_messages.mbt — Anthropic Messages request shape for a custom
/// endpoint. Encoding of system blocks, messages, tools, and streaming events
/// comes from `posoco-kit-messages`; this file owns the request shape:
///
/// - system turns lift into the top-level `system` field;
/// - `max_tokens` is mandatory on this wire: the turn's own ceiling when the
///   host supplied one, otherwise the configured default;
/// - a selected effort level turns thinking on (`thinking.type = enabled`);
///   the budget is left to the endpoint because a level name is posoco
///   vocabulary, not a token count, and no number is invented for it;
///   `off` sends no thinking surface;
/// - streaming is requested in the body, which is what gateways key on.

///|
fn messages_url(config : CustomConfig) -> String {
  config.base_url + config.endpoint_prefix + "/messages"
}

///|
/// Build the Messages request body.
fn build_messages_request(
  config : CustomConfig,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream~ : Bool = false,
) -> Json raise @posoco.ModelError {
  let shaped = shape_custom_images(
    @chatkit.fold_tool_attachments(messages, config.supports_images),
    config.supports_images,
  )
  let (system, transcript) = custom_split_system(shaped)
  let system_json : Json? = if system.is_empty() {
    None
  } else {
    Some(@messages.system_to_wire(content=system))
  }
  let wire_messages : Array[Json] = []
  for msg in transcript {
    for block in @messages.message_to_wire(msg) {
      wire_messages.push(block)
    }
  }
  let wire_tools : Array[Json] = tools.map(tool => @messages.tool_to_wire(tool~))
  let extra : Array[(String, Json)] = if stream {
    [("stream", Json::boolean(true))]
  } else {
    []
  }
  let thinking : @messages.ThinkingConfig? = match config.reasoning_effort {
    Some(_) => Some(@messages.ThinkingConfig::Enabled(budget_tokens=None))
    None => None
  }
  let max_tokens = match options.max_output_tokens {
    Some(n) => n
    None => config.max_output_tokens
  }
  @messages.encode_request(
    model=config.model,
    max_tokens~,
    system=system_json,
    messages=wire_messages,
    tools=wire_tools,
    options=@messages.MessagesRequestOptions::MessagesRequestOptions(
      temperature=options.temperature,
      thinking~,
      extra_top_level=extra,
    ),
  )
}
