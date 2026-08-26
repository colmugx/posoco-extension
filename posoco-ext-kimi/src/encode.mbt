///|
/// Wire encoder: convert kernel canonical types to kimi API JSON.
///
/// Kimi-specific rules (verified against kimi-code/kosong source):
/// - reasoning_content is UNCONDITIONALLY preserved on all assistant messages.
///   Removing it breaks prefix cache (byte-for-byte longest-prefix matching)
///   and disrupts reasoning signature continuity. thinking.keep="all" is the
///   default policy.
/// - Messages are append-only — no message is ever skipped or reordered.
/// - Non-assistant messages never carry reasoning_content.
/// - Tool call arguments are JSON strings (kimi convention).
/// - max_tokens is sent as max_completion_tokens (kimi convention).
/// - tool_call_id must match [a-zA-Z0-9_-] and be <= 64 chars.
/// - $-prefixed tool names serialize as builtin_function.
/// - reasoning_effort goes inside thinking.effort, not top-level.

///|
/// Sanitize a tool call id for Kimi: replace any char outside [a-zA-Z0-9_-]
/// with `_`, then truncate to 64 chars. Kimi rejects ids with colons,
/// slashes, pipes, etc. (verified against kimi-code/kosong tool-call-id.ts).
fn sanitize_tool_call_id(id : String) -> String {
  let buf = StringBuilder::new()
  for ch in id {
    if (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '_' ||
      ch == '-' {
      buf.write_char(ch)
    } else {
      buf.write_char('_')
    }
  }
  let sanitized = buf.to_string()
  if sanitized.length() > 64 {
    sanitized.sub(end=64).to_owned()
  } else {
    sanitized
  }
}

///|
/// Encode a kernel Message into a kimi chat message JSON object.
fn encode_message(msg : @posoco.Message, supports_images : Bool) -> Json {
  let (role, content_blocks, tool_calls, tool_call_id, reasoning_text) = match
    msg {
    SystemMessage(content~) => ("system", content, [], None, None)
    UserMessage(content~) => ("user", content, [], None, None)
    AssistantMessage(content~, tool_calls~, reasoning~, finish_reason~) => {
      let _ = finish_reason
      // Read .content directly — Reasoning's Show impl only renders a
      // length summary ("Reasoning(N chars)"), which would corrupt the wire.
      let reasoning_str = match reasoning {
        Some(r) => Some(r.content)
        None => None
      }
      ("assistant", content, tool_calls, None, reasoning_str)
    }
    ToolMessage(call_id~, tool_name~, outcome~) => {
      // Tool messages carry the outcome content as the wire "content", plus
      // the sanitized `tool_call_id` of the assistant tool_call they answer
      // (same charset/length rules as assistant-side ids, so correlation
      // matches byte-for-byte).
      let outcome_text = outcome_to_wire_text(outcome)
      let tool_blocks : Array[@posoco.Content] = [
        @posoco.Content::Text(outcome_text),
      ]
      let _ = tool_name
      ("tool", tool_blocks, [], Some(call_id.to_string()), None)
    }
  }
  // Shared content encoding: string form by default (kimi rejects content
  // arrays for text-only models), typed parts when the model declares image
  // input, explicit placeholder downgrade otherwise.
  let encoded = @chatkit.encode_chat_message_content(
    content_blocks,
    supports_images~,
  )
  let obj : Map[String, Json] = { "role": Json::string(role) }
  match tool_call_id {
    Some(id) => obj["tool_call_id"] = Json::string(sanitize_tool_call_id(id))
    None => ()
  }
  // K3: Kimi rejects empty content on assistant messages ("must not be empty").
  // When an assistant message only has tool_calls, omit content entirely.
  // Non-assistant messages always carry content (even if empty). The parts
  // form is non-empty by construction (it only appears when images exist).
  match encoded {
    TextContent(s) =>
      if s.length() > 0 || tool_calls.length() == 0 {
        obj["content"] = Json::string(s)
      }
    PartsContent(parts) => obj["content"] = Json::array(parts)
  }
  // Tool calls (assistant messages requesting tool execution)
  if tool_calls.length() > 0 {
    let tc_arr = tool_calls.map(fn(tc) {
      let tc_obj : Map[String, Json] = {
        "id": Json::string(sanitize_tool_call_id(tc.call_id.to_string())),
        "type": Json::string("function"),
        "function": Json::object({
          "name": Json::string(tc.name.to_string()),
          "arguments": Json::string(tc.arguments.stringify()),
        }),
      }
      Json::object(tc_obj)
    })
    obj["tool_calls"] = Json::array(tc_arr)
  }
  // reasoning_content: Kimi's prefix cache uses byte-for-byte longest-prefix
  // matching. Removing reasoning_content from any assistant message breaks
  // the contiguous prefix alignment and invalidates the cache. The
  // thinking.keep="all" policy (kimi-code default) mandates unconditional
  // replay of reasoning on ALL assistant messages, regardless of tool_calls.
  if role == "assistant" {
    match reasoning_text {
      Some(r) => obj["reasoning_content"] = Json::string(r)
      None => ()
    }
  }
  Json::object(obj)
}

///|
/// Flatten a ToolOutcome to the wire text kimi expects in a tool-role
/// message's `content` field. Business errors surface their message;
/// runtime failures surface their category+message.
fn outcome_to_wire_text(outcome : @posoco.ToolOutcome) -> String {
  match outcome {
    Success(content~, ..) => content
    ToolReportedError(content~, ..) => content
    RuntimeFailure(message~, ..) => message
    NotExecuted(reason~, ..) => reason.to_string()
  }
}

///|
/// Encode kernel ToolDef array into kimi tool definitions.
/// $-prefixed names are Kimi builtin functions (e.g. $web_search): they
/// use type "builtin_function" and omit parameters/description.
fn encode_tools(tools : Array[@posoco.ToolDef]) -> Json {
  Json::array(
    tools.map(fn(t) {
      let name = t.name.to_string()
      if name.has_prefix("$") {
        Json::object({
          "type": Json::string("builtin_function"),
          "function": Json::object({ "name": Json::string(name) }),
        })
      } else {
        Json::object({
          "type": Json::string("function"),
          "function": Json::object({
            "name": Json::string(name),
            "description": Json::string(t.description),
            "parameters": t.input_schema,
          }),
        })
      }
    }),
  )
}

///|
/// Build the full chat completions request body.
fn build_chat_request(
  ctx : @devkit.ExtContext,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  model : String,
  stream : Bool,
  thinking_json : Json,
  cache_key : String?,
  reasoning_effort_str? : String? = None,
  supports_images? : Bool = false,
) -> Json {
  let body : Map[String, Json] = {
    "model": Json::string(model),
    "messages": Json::array(
      messages.map(fn(m) { encode_message(m, supports_images) }),
    ),
  }
  if tools.length() > 0 {
    body["tools"] = encode_tools(tools)
  }
  match options.temperature {
    Some(t) => body["temperature"] = Json::number(t)
    None => ()
  }
  match options.max_output_tokens {
    Some(n) => body["max_completion_tokens"] = Json::number(n.to_double())
    None => ()
  }
  body["thinking"] = thinking_json
  match reasoning_effort_str {
    Some(effort) => body["reasoning_effort"] = Json::string(effort)
    None => ()
  }
  match cache_key {
    Some(k) => body["prompt_cache_key"] = Json::string(k)
    None => ()
  }
  if stream {
    body["stream"] = Json::boolean(true)
    body["stream_options"] = Json::object({
      "include_usage": Json::boolean(true),
    })
  }
  let _ = ctx
  Json::object(body)
}

///|
/// Enabled thinking with keep="all" and optional effort inside the thinking
/// object (NOT top-level reasoning_effort — only kimi-k3 supports that).
fn enabled_thinking_json(effort : String?) -> Json {
  let obj : Map[String, Json] = {
    "type": Json::string("enabled"),
    "keep": Json::string("all"),
  }
  match effort {
    Some(e) => obj["effort"] = Json::string(e)
    None => ()
  }
  Json::object(obj)
}
