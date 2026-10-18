///|
/// execution.mbt — the three protocol adapters.
///
/// Each adapter consumes a validated `MagpieProtocolPlan`, encodes through
/// its protocol kit, speaks exactly the planned endpoint, and returns the
/// completion together with an execution report. There is no fallback: one
/// call, one protocol, one endpoint; failures raise.
///
/// Protocol-native semantics travel inside the kits: Messages thinking
/// blocks are captured into the kit's replay envelope on decode and
/// re-expanded on encode; Responses reasoning items ride `Reasoning.raw`
/// verbatim; cache marking is policy-driven and defaults to leaving the
/// request untouched.

///|
/// Observability of one completed execution. The session identity itself is
/// never reported — only whether affinity was attached.
pub(all) struct MagpieExecutionReport {
  /// The opaque model ID the execution asked for (the active selection).
  requested_model : String
  /// The model the gateway says actually served the request, when the
  /// protocol response names one.
  served_model : String?
  protocol : MagpieProtocol
  kind : MagpieEndpointKind
  endpoint_path : String
  /// Canonical usage projection for the run budget.
  usage : @posoco.Usage?
  /// Native cache-read tokens when the protocol reports them.
  cache_read_tokens : Int32?
  /// Native cache-write (creation) tokens when the protocol reports them.
  cache_write_tokens : Int32?
  /// Protocol-level finish reason, canonically mapped.
  finish_reason : @posoco.FinishReason
  /// Gateway response identifier, when the protocol response names one.
  response_id : String?
  lossy_opt_in : Bool
  /// Whether the X-Magpie-Session affinity header was attached.
  session_identified : Bool
} derive(Eq, Debug)

///|
pub extend MagpieExecutionReport with Eq::{not_equal, equal}

///|
pub extend MagpieExecutionReport with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Default output budget when the caller does not bound the call. Magpie's
/// Messages dialect requires an explicit `max_tokens`.
const DEFAULT_MAX_OUTPUT_TOKENS : Int32 = 8192

///|
/// Streaming read loops yield to the event loop at most every 16ms; the
/// pause is also where coroutine cancellation lands.
const STREAM_YIELD_MS : Int64 = 16L

///|
/// Per-call execution context shared by the three adapters.
priv struct ExecCall {
  config : MagpieConfig
  transport : &MagpieTransport
  plan : MagpieProtocolPlan
  model_id : String
  effort : String?
  session : String?
  lossy : Bool
  supports_images : Bool
}

///|
/// Runs one planned execution: dispatches to the protocol adapter and
/// returns the model call result plus the execution report.
async fn execute_planned(
  call : ExecCall,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> (@posoco.ModelCallResult, MagpieExecutionReport) raise @posoco.ModelError {
  match call.plan.protocol {
    Messages => execute_messages(call, messages, tools, options, stream)
    Responses => execute_responses(call, messages, tools, options, stream)
    ChatCompletions => execute_chat(call, messages, tools, options, stream)
  }
}

///|
/// Resolves the output budget: the caller's bound when given, otherwise
/// the execution default.
fn output_budget(options : @posoco.ChatOptions) -> Int32 {
  match options.max_output_tokens {
    Some(n) => n
    None => DEFAULT_MAX_OUTPUT_TOKENS
  }
}

///|
/// The `data:` payload of one SSE line, when the line frames one. This is
/// transport framing only; event decoding belongs to the protocol kits.
fn sse_payload(raw_line : String) -> String? {
  let trimmed = raw_line.trim()
  if trimmed.has_prefix("data:") {
    let payload = trimmed["data:".length():].trim().to_owned()
    if payload.length() > 0 {
      return Some(payload)
    }
  }
  None
}

///|
/// Non-streaming POST helper: sends the body, classifies the status, and
/// returns the parsed response JSON.
async fn post_response_json(
  call : ExecCall,
  stage : String,
  endpoint : String,
  headers : Map[String, String],
  body : Json,
) -> Json raise @posoco.ModelError {
  let (code, text) = call.transport.post(
    endpoint,
    headers~,
    body=body.stringify(),
  ) catch {
    error => raise transport_error("\{stage}.post", error.to_string())
  }
  require_http_success(stage, code, text)
  @json.parse(text) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "magpie response parse failure (stage=\{stage}.json, body_chars=\{text.length()})",
      )
  }
}

///|
/// Opens one SSE stream, classifying the status before any event is read.
/// A non-2xx answer drains into bounded diagnostics and raises; a 2xx
/// answer returns the open stream.
async fn open_event_stream(
  call : ExecCall,
  stage : String,
  endpoint : String,
  headers : Map[String, String],
  body : Json,
) -> &MagpieEventStream raise @posoco.ModelError {
  let (code, stream) = call.transport.post_stream(
    endpoint,
    headers~,
    body=body.stringify(),
  ) catch {
    error => raise transport_error("\{stage}.post_stream", error.to_string())
  }
  if !is_http_success(code) {
    let err_body = drain_error_body(stream) catch { _ => "" }
    require_http_success(stage, code, err_body)
    // require_http_success only raises; unreachable fallthrough:
    raise @posoco.ModelError::Transport(
      "magpie transport failure (stage=\{stage}, status=\{code})",
    )
  }
  stream
}

///|
/// Anthropic Messages execution through the messages kit. Thinking blocks
/// are captured into the kit's replay envelope on decode and re-expanded on
/// encode; usage and cache-creation accounting stay protocol-native; cache
/// marking follows the request options and defaults to untouched.
#warnings("-fragile_catch_all")
async fn execute_messages(
  call : ExecCall,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> (@posoco.ModelCallResult, MagpieExecutionReport) raise @posoco.ModelError {
  let endpoint = execution_endpoint(call.config, call.plan)
  let streaming = stream is Stream(_)
  let headers = exec_headers(call.config, call.session, streaming~)
  // Shape the transcript for the model's declared input modalities, lift
  // system content, and encode through the kit (the kit owns thinking-block
  // replay envelopes, tool wiring, and content blocks).
  let shaped = shape_for_images(messages, call.supports_images)
  let (system, transcript) = split_system(shaped)
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
  // The gateway keys Messages streaming on the body field, not on the
  // Accept header: without this flag a streamed call gets one buffered
  // JSON body and the SSE terminal check reports a truncated stream.
  let extra : Array[(String, Json)] = [("stream", Json::boolean(streaming))]
  match call.effort {
    Some(effort) => extra.push(("reasoning_effort", Json::string(effort)))
    None => ()
  }
  let request_options = @messages.MessagesRequestOptions::MessagesRequestOptions(
    temperature=options.temperature,
    extra_top_level=extra,
  )
  let body = @messages.encode_request(
    model=call.model_id,
    max_tokens=output_budget(options),
    system=system_json,
    messages=wire_messages,
    tools=wire_tools,
    options=request_options,
  )
  // Non-streaming: buffered POST, kit-side parse.
  if !streaming {
    let root = post_response_json(call, "messages", endpoint, headers, body)
    let result = @messages.parse_response(provider="magpie", root)
    return (
      { completion: result.completion, processed_messages: messages, },
      messages_report(call, result, endpoint),
    )
  }
  // Streaming: kit SSE decoder plus kit event processor; EOF before the
  // terminal marker is an incomplete stream, classified by the kit.
  let event_stream = open_event_stream(
    call, "messages", endpoint, headers, body,
  )
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let state = @messages.MessagesSseState::MessagesSseState()
  let decoder = @messages.SseDecoder::SseDecoder()
  let mut done = false
  let mut last_yield = @async.now()
  while !done {
    let line = event_stream.next_line() catch {
      error => {
        event_stream.close_stream() catch {
          _ => ()
        }
        raise transport_error("messages.read_stream", error.to_string())
      }
    }
    match line {
      Some(raw) =>
        for event in decoder.push(raw + "\n") {
          if magpie_stream_transient(event.data) {
            event_stream.close_stream() catch { _ => () }
            raise magpie_transient_error("messages.stream", "mid_reply")
          }
          done = @messages.process_messages_event(
            provider="magpie",
            event_name=event.name,
            data=event.data,
            acc~,
            on_chunk=stream_callback(stream),
            state~,
          ) catch {
            error => {
              event_stream.close_stream() catch {
                _ => ()
              }
              raise error
            }
          }
        }
      None => {
        event_stream.close_stream() catch {
          _ => ()
        }
        match
          @messages.classify_stream_termination(
            provider="magpie",
            @messages.StreamTermination::CleanEof,
          ) {
          Some(_) => raise magpie_transient_error("messages.eof", "truncated_stream")
          None => done = true
        }
      }
    }
    let now = @async.now()
    if now - last_yield >= STREAM_YIELD_MS {
      @async.pause()
      last_yield = now
    }
  }
  event_stream.close_stream() catch {
    _ => ()
  }
  match
    @messages.classify_stream_termination(
      provider="magpie",
      @messages.StreamTermination::ExplicitTerminal,
    ) {
    Some(error) => raise error
    None => ()
  }
  let result = @messages.messages_stream_result(provider="magpie", acc~, state~)
  (
    { completion: result.completion, processed_messages: messages, },
    messages_report(call, result, endpoint),
  )
}

///|
/// Builds the execution report from a messages kit result. Usage stays
/// protocol-native: canonical projection for the budget, native cache
/// creation/read numbers for observability.
fn messages_report(
  call : ExecCall,
  result : @messages.MessagesResult,
  endpoint : String,
) -> MagpieExecutionReport raise @posoco.ModelError {
  // Both cache-creation dialects: the nested per-ttl object and the legacy
  // flat counter. The native numbers stay separate from the canonical use.
  let cache_write = match result.cache_creation {
    Some(creation) =>
      match
        (creation.ephemeral_5m_input_tokens, creation.ephemeral_1h_input_tokens) {
        (Some(five), Some(one)) => Some(five + one)
        (Some(five), None) => Some(five)
        (None, Some(one)) => Some(one)
        (None, None) =>
          match result.usage {
            Some(usage) => usage.cache_creation_input_tokens
            None => None
          }
      }
    None =>
      match result.usage {
        Some(usage) => usage.cache_creation_input_tokens
        None => None
      }
  }
  let cache_read = match result.usage {
    Some(usage) => usage.cache_read_input_tokens
    None => None
  }
  let usage = match result.usage {
    Some(usage) => Some(usage.to_canonical())
    None => None
  }
  let served = if result.model is "" { None } else { Some(result.model) }
  let response_id = if result.response_id is "" {
    None
  } else {
    Some(result.response_id)
  }
  {
    requested_model: call.model_id,
    served_model: served,
    protocol: call.plan.protocol,
    kind: call.plan.kind,
    endpoint_path: endpoint,
    usage,
    cache_read_tokens: cache_read,
    cache_write_tokens: cache_write,
    finish_reason: result.completion.message.finish_reason,
    response_id,
    lossy_opt_in: call.lossy,
    session_identified: call.session is Some(_),
  }
}

///|
/// Assembles a Responses request: input items come straight from the kit's
/// message conversion (reasoning items replay verbatim from
/// `Reasoning.raw`), tools through the kit's wire format.
fn responses_request(
  call : ExecCall,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  streaming : Bool,
) -> Json {
  let folded = @responses.fold_tool_attachments(messages, call.supports_images)
  let items : Array[Json] = []
  for msg in folded {
    for item in @responses.message_to_responses_items(msg) {
      items.push(item)
    }
  }
  let body : Map[String, Json] = {
    "model": Json::string(call.model_id),
    "input": Json::array(items),
    "stream": Json::boolean(streaming),
  }
  if tools.length() > 0 {
    body["tools"] = Json::array(
      tools.map(tool => @responses.tool_to_responses_wire(tool)),
    )
  }
  match options.temperature {
    Some(t) => body["temperature"] = Json::number(t)
    None => ()
  }
  match options.max_output_tokens {
    Some(n) => body["max_output_tokens"] = Json::number(n.to_double())
    None => ()
  }
  match call.effort {
    Some(effort) =>
      body["reasoning"] = Json::object({ "effort": Json::string(effort) })
    None => ()
  }
  Json::object(body)
}

///|
/// Attaches the reasoning items captured from output_item events so later
/// requests replay them verbatim (the API keeps them opaque; only the raw
/// item payload replays, never a re-serialization).
fn attach_reasoning_items(
  completion : @posoco.Completion,
  state : @responses.SseStreamState,
) -> @posoco.Completion {
  if state.items.is_empty() {
    return completion
  }
  let content = match completion.message.reasoning {
    Some(reasoning) =>
      if reasoning.content == "" {
        state.summary
      } else {
        reasoning.content
      }
    None => state.summary
  }
  @posoco.Completion::Completion(
    content=completion.message.content,
    tool_calls=completion.message.tool_calls,
    reasoning=Some({ content, raw: Some(Json::array(state.items)), }),
    finish_reason=completion.message.finish_reason,
    usage=completion.usage,
  )
}

///|
/// OpenAI Responses execution through the responses kit. Reasoning items
/// replay verbatim; usage comes from the terminal response; the gateway's
/// reported model and response id are surfaced when present.
#warnings("-fragile_catch_all")
async fn execute_responses(
  call : ExecCall,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> (@posoco.ModelCallResult, MagpieExecutionReport) raise @posoco.ModelError {
  let endpoint = execution_endpoint(call.config, call.plan)
  let streaming = stream is Stream(_)
  let headers = exec_headers(call.config, call.session, streaming~)
  let body = responses_request(call, messages, tools, options, streaming)
  if !streaming {
    let root = post_response_json(call, "responses", endpoint, headers, body)
    @responses.validate_terminal_response(
      provider="magpie",
      root,
      "chat.nonstream",
    )
    let completion = @responses.parse_responses_response(
      provider="magpie",
      root,
    )
    let usage = @responses.extract_usage(provider="magpie", root)
    return (
      { completion, processed_messages: messages, },
      responses_report(call, endpoint, completion, usage, root),
    )
  }
  let event_stream = open_event_stream(
    call, "responses", endpoint, headers, body,
  )
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let sse_state = @responses.SseStreamState::SseStreamState()
  let on_chunk = stream_callback(stream)
  let mut done = false
  let mut last_yield = @async.now()
  while !done {
    let line = event_stream.next_line() catch {
      error => {
        event_stream.close_stream() catch {
          _ => ()
        }
        raise transport_error("responses.read_stream", error.to_string())
      }
    }
    match line {
      Some(raw) =>
        match sse_payload(raw) {
          Some(payload) => {
            if magpie_stream_transient(payload) {
              event_stream.close_stream() catch { _ => () }
              raise magpie_transient_error("responses.stream", "mid_reply")
            }
            done = @responses.process_responses_sse(
              provider="magpie",
              payload,
              acc,
              on_chunk,
              state=sse_state,
            ) catch {
              error => {
                event_stream.close_stream() catch {
                  _ => ()
                }
                raise error
              }
            }
          }
          None => ()
        }
      None => {
        event_stream.close_stream() catch { _ => () }
        raise magpie_transient_error("responses.eof", "truncated_stream")
      }
    }
    let now = @async.now()
    if now - last_yield >= STREAM_YIELD_MS {
      @async.pause()
      last_yield = now
    }
  }
  event_stream.close_stream() catch {
    _ => ()
  }
  match
    @responses.classify_stream_termination(
      provider="magpie",
      @responses.StreamTermination::ExplicitTerminal,
    ) {
    Some(error) => raise error
    None => ()
  }
  @responses.validate_stream_tool_calls(provider="magpie", acc)
  let completion = attach_reasoning_items(
    @responses.responses_stream_completion(provider="magpie", acc),
    sse_state,
  )
  (
    { completion, processed_messages: messages, },
    responses_report(call, endpoint, completion, completion.usage, Json::null()),
  )
}

///|
fn responses_report(
  call : ExecCall,
  endpoint : String,
  completion : @posoco.Completion,
  usage : @posoco.Usage?,
  root : Json,
) -> MagpieExecutionReport {
  let fields = match root {
    Json::Object(fields) => fields
    _ => Map::from_array([])
  }
  let served = match fields.get("model") {
    Some(Json::String(model)) => Some(model)
    _ => None
  }
  let response_id = match fields.get("id") {
    Some(Json::String(id)) => Some(id)
    _ => None
  }
  let cache_read = match usage {
    Some(usage) => usage.cached_input_tokens
    None => None
  }
  {
    requested_model: call.model_id,
    served_model: served,
    protocol: call.plan.protocol,
    kind: call.plan.kind,
    endpoint_path: endpoint,
    usage,
    cache_read_tokens: cache_read,
    cache_write_tokens: None,
    finish_reason: completion.message.finish_reason,
    response_id,
    lossy_opt_in: call.lossy,
    session_identified: call.session is Some(_),
  }
}

///|
/// The stream callback out of a `StreamMode`, for kits that take the chunk
/// sink positionally. `NoStream` never reaches the adapters' stream paths.
fn stream_callback(
  stream : @posoco.StreamMode,
) -> (@posoco.StreamChunk) -> Unit {
  match stream {
    Stream(on_chunk) => on_chunk
    NoStream => fn(_chunk) { () }
  }
}

///|
/// Encodes one transcript message in the Chat Completions dialect through
/// the chat kit's content encoder. Assistant reasoning echoes as
/// `reasoning_content` text — the dialect has no signature channel, which
/// is exactly why planning rates its thinking replay Unknown.
fn encode_chat_message(msg : @posoco.Message, supports_images : Bool) -> Json {
  let (role, content_blocks, tool_calls, tool_call_id, reasoning_text) = match
    msg {
    @posoco.Message::SystemMessage(content~) =>
      ("system", content, [], None, None)
    @posoco.Message::UserMessage(content~) => ("user", content, [], None, None)
    @posoco.Message::AssistantMessage(content~, tool_calls~, reasoning~, ..) => {
      let reasoning_text = match reasoning {
        Some(value) => Some(value.content)
        None => None
      }
      ("assistant", content, tool_calls, None, reasoning_text)
    }
    @posoco.Message::ToolMessage(call_id~, tool_name~, outcome~) => {
      let _ = tool_name
      let blocks : Array[@posoco.Content] = [
        @posoco.Content::Text(@chatkit.outcome_wire_text(outcome)),
      ]
      ("tool", blocks, [], Some(call_id.to_string()), None)
    }
  }
  let content_json : Json = match
    @chatkit.encode_chat_message_content(content_blocks, supports_images~) {
    TextContent(value) => Json::string(value)
    PartsContent(parts) => Json::array(parts)
  }
  let obj : Map[String, Json] = {
    "role": Json::string(role),
    "content": content_json,
  }
  match tool_call_id {
    Some(value) => obj["tool_call_id"] = Json::string(value)
    None => ()
  }
  if tool_calls.length() > 0 {
    obj["tool_calls"] = Json::array(
      tool_calls.map(fn(call) {
        Json::object({
          "id": Json::string(call.call_id.to_string()),
          "type": Json::string("function"),
          "function": Json::object({
            "name": Json::string(call.name.to_string()),
            "arguments": Json::string(call.arguments.stringify()),
          }),
        })
      }),
    )
  }
  if role is "assistant" {
    match reasoning_text {
      Some(value) =>
        if value.length() > 0 {
          obj["reasoning_content"] = Json::string(value)
        }
      None => ()
    }
  }
  Json::object(obj)
}

///|
fn encode_chat_tools(tools : Array[@posoco.ToolDef]) -> Json {
  Json::array(
    tools.map(tool => {
      Json::object({
        "type": Json::string("function"),
        "function": Json::object({
          "name": Json::string(tool.name.to_string()),
          "description": Json::string(tool.description),
          "parameters": tool.input_schema,
        }),
      })
    }),
  )
}

///|
fn chat_parse_error(stage : String, detail : String) -> @posoco.ModelError {
  @posoco.ModelError::ResponseParse(
    "magpie response parse failure (stage=chat.\{stage}, category=\{detail})",
  )
}

///|
/// Maps a Chat Completions finish-reason string onto the canonical reason.
fn chat_finish_reason(reason : String?) -> @posoco.FinishReason {
  match reason {
    Some("stop") => Stop
    Some("length") => Length
    Some("tool_calls") | Some("function") => ToolCalls
    Some(other) => Other(other)
    None => Stop
  }
}

///|
/// Decodes a buffered Chat Completions response: choices[0] projection with
/// strict shapes, native usage kept for the report.
fn decode_chat_response(
  root : Json,
) -> (@posoco.Completion, @posoco.Usage?, String?, String?) raise @posoco.ModelError {
  guard root is Json::Object(fields) else {
    raise chat_parse_error("response", "not_object")
  }
  let served = match fields.get("model") {
    Some(Json::String(model)) => Some(model)
    _ => None
  }
  let response_id = match fields.get("id") {
    Some(Json::String(id)) => Some(id)
    _ => None
  }
  let choices = match fields.get("choices") {
    Some(Json::Array(values)) => values
    Some(_) => raise chat_parse_error("choices", "wrong_type")
    None => raise chat_parse_error("choices", "missing")
  }
  guard choices is [first, ..] else {
    raise chat_parse_error("choices", "empty")
  }
  guard first is Json::Object(choice) else {
    raise chat_parse_error("choice", "not_object")
  }
  let message = match choice.get("message") {
    Some(Json::Object(value)) => value
    Some(_) => raise chat_parse_error("message", "wrong_type")
    None => raise chat_parse_error("message", "missing")
  }
  let text = match message.get("content") {
    Some(Json::String(value)) => value
    Some(Json::Null) | None => ""
    Some(_) => raise chat_parse_error("message.content", "wrong_type")
  }
  let reasoning : @posoco.Reasoning? = match message.get("reasoning_content") {
    Some(Json::String(value)) =>
      if value is "" {
        None
      } else {
        Some({ content: value, raw: None, })
      }
    Some(Json::Null) | None => None
    Some(_) => raise chat_parse_error("message.reasoning_content", "wrong_type")
  }
  let tool_calls : Array[@posoco.ToolCall] = match message.get("tool_calls") {
    Some(Json::Array(values)) => {
      let result : Array[@posoco.ToolCall] = []
      for value in values {
        guard value is Json::Object(call) else {
          raise chat_parse_error("tool", "not_object")
        }
        let id = match call.get("id") {
          Some(Json::String(id)) if id != "" => id
          _ => raise chat_parse_error("tool.id", "missing_or_wrong_type")
        }
        guard call.get("function") is Some(Json::Object(function)) else {
          raise chat_parse_error("tool.function", "missing_or_wrong_type")
        }
        let name = match function.get("name") {
          Some(Json::String(name)) if name != "" => name
          _ => raise chat_parse_error("tool.name", "missing_or_wrong_type")
        }
        let arguments = match function.get("arguments") {
          Some(Json::String(text)) => text
          _ => raise chat_parse_error("tool.arguments", "missing_or_wrong_type")
        }
        let parsed : Json = @json.parse(arguments) catch {
          _ =>
            raise chat_parse_error(
              "tool.arguments_json",
              "malformed, payload_chars=\{arguments.length()}",
            )
        }
        result.push({
          call_id: @posoco.CallId::unchecked(id),
          name: @posoco.ToolName::unchecked(name),
          arguments: parsed,
        })
      }
      result
    }
    Some(Json::Null) | None => []
    Some(_) => raise chat_parse_error("message.tool_calls", "wrong_type")
  }
  let finish_reason = chat_finish_reason(
    match choice.get("finish_reason") {
      Some(Json::String(reason)) => Some(reason)
      _ => None
    },
  )
  let usage : @posoco.Usage? = match fields.get("usage") {
    Some(Json::Object(fields)) => {
      let read = (field : String) => {
        match fields.get(field) {
          Some(Json::Number(value, ..)) => Some(value.to_int())
          _ => None
        }
      }
      Some({
        input_tokens: read("prompt_tokens"),
        output_tokens: read("completion_tokens"),
        total_tokens: read("total_tokens"),
        cached_input_tokens: @chatkit.cached_input_tokens_from_usage(fields),
        uncached_input_tokens: @chatkit.uncached_input_tokens_from_usage(fields),
      })
    }
    _ => None
  }
  let completion = @posoco.Completion::Completion(
    content=if text is "" { [] } else { [@posoco.Content::Text(text)] },
    tool_calls~,
    reasoning~,
    finish_reason~,
    usage~,
  )
  (completion, usage, served, response_id)
}

///|
/// OpenAI Chat Completions execution through the chat kit: the kit owns
/// content encoding and SSE event decoding; the adapter assembles the
/// request and decodes the buffered response shape.
#warnings("-fragile_catch_all")
async fn execute_chat(
  call : ExecCall,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> (@posoco.ModelCallResult, MagpieExecutionReport) raise @posoco.ModelError {
  let endpoint = execution_endpoint(call.config, call.plan)
  let streaming = stream is Stream(_)
  let headers = exec_headers(call.config, call.session, streaming~)
  let folded = @chatkit.fold_tool_attachments(messages, call.supports_images)
  let body_map : Map[String, Json] = {
    "model": Json::string(call.model_id),
    "messages": Json::array(
      folded.map(msg => encode_chat_message(msg, call.supports_images)),
    ),
    "stream": Json::boolean(streaming),
  }
  if tools.length() > 0 {
    body_map["tools"] = encode_chat_tools(tools)
  }
  match options.temperature {
    Some(t) => body_map["temperature"] = Json::number(t)
    None => ()
  }
  body_map["max_tokens"] = Json::number(output_budget(options).to_double())
  match call.effort {
    Some(effort) => body_map["reasoning_effort"] = Json::string(effort)
    None => ()
  }
  let body = Json::object(body_map)
  if !streaming {
    let root = post_response_json(call, "chat", endpoint, headers, body)
    let (completion, usage, served, response_id) = decode_chat_response(root)
    return (
      { completion, processed_messages: messages, },
      {
        requested_model: call.model_id,
        served_model: served,
        protocol: call.plan.protocol,
        kind: call.plan.kind,
        endpoint_path: endpoint,
        usage,
        cache_read_tokens: match usage {
          Some(usage) => usage.cached_input_tokens
          None => None
        },
        cache_write_tokens: None,
        finish_reason: completion.message.finish_reason,
        response_id,
        lossy_opt_in: call.lossy,
        session_identified: call.session is Some(_),
      },
    )
  }
  let event_stream = open_event_stream(call, "chat", endpoint, headers, body)
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let on_chunk = stream_callback(stream)
  let mut done = false
  let mut last_yield = @async.now()
  while !done {
    let line = event_stream.next_line() catch {
      error => {
        event_stream.close_stream() catch {
          _ => ()
        }
        raise transport_error("chat.read_stream", error.to_string())
      }
    }
    match line {
      Some(raw) =>
        match sse_payload(raw) {
          // Keep draining past a recorded finish so late usage chunks are
          // not lost; [DONE] ends the loop.
          Some(payload) =>
            if payload is "[DONE]" {
              done = true
            } else {
              if magpie_stream_transient(payload) {
                event_stream.close_stream() catch { _ => () }
                raise magpie_transient_error("chat.stream", "mid_reply")
              }
              let _ = @chatkit.process_chat_completions_sse(
                provider="magpie",
                payload,
                acc,
                on_chunk,
              ) catch {
                error => {
                  event_stream.close_stream() catch {
                    _ => ()
                  }
                  raise error
                }
              }
            }
          None => ()
        }
      None => {
        event_stream.close_stream() catch {
          _ => ()
        }
        raise magpie_transient_error("chat.eof", "truncated_stream")
      }
    }
    let now = @async.now()
    if now - last_yield >= STREAM_YIELD_MS {
      @async.pause()
      last_yield = now
    }
  }
  event_stream.close_stream() catch {
    _ => ()
  }
  for snapshot in acc.tool_calls() {
    if snapshot.id is "" || snapshot.name is "" {
      raise @posoco.ModelError::ResponseParse(
        "magpie response parse failure (stage=chat.stream, category=incomplete_tool_call)",
      )
    }
  }
  let completion = acc.to_completion()
  (
    { completion, processed_messages: messages, },
    {
      requested_model: call.model_id,
      served_model: None,
      protocol: call.plan.protocol,
      kind: call.plan.kind,
      endpoint_path: endpoint,
      usage: completion.usage,
      cache_read_tokens: match completion.usage {
        Some(usage) => usage.cached_input_tokens
        None => None
      },
      cache_write_tokens: None,
      finish_reason: completion.message.finish_reason,
      response_id: None,
      lossy_opt_in: call.lossy,
      session_identified: call.session is Some(_),
    },
  )
}
