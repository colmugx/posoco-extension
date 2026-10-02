///|
/// Responses V2 compact uses the ordinary request path for every auth kind.
/// The body comes from the same shared private preparation as chat
/// (instructions/tools/use_responses_lite encoding); compact only appends
/// the trailing `compaction_trigger` request control plus its compact-only
/// control fields. The trigger is a request control; it is never part of the
/// returned history snapshot used for retained-history assembly.
fn build_compact_v2_request(
  config : OpenAIConfig,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  session_id : String,
) -> (Json, Array[Json]) raise @posoco.ModelError {
  let input = openai_encode_window_items(messages)
  let (history, instructions) = split_openai_base_instructions(input)
  // The request input is deep-copied so later envelope mutation cannot alias
  // the retained-history snapshot; the trigger rides after the copied items.
  let request_input = history.map(json_deep_copy)
  request_input.push(
    Json::object(
      Map::from_array([("type", Json::string("compaction_trigger"))]),
    ),
  )
  let body = openai_prepare_request_body(
    config,
    session_id,
    request_input,
    instructions,
    tools,
    options,
    stream=true,
    extra_fields=[
      ("tool_choice", Json::string("auto")),
      // Prompt value; the shared Lite shaping pins it to false when the
      // current model metadata selects Responses Lite.
      ("parallel_tool_calls", Json::boolean(true)),
      ("include", Json::array([Json::string("reasoning.encrypted_content")])),
      ("prompt_cache_key", Json::string(session_id)),
    ],
  )
  (body, history)
}

///|
priv struct CompactV2Stream {
  mut compaction_count : Int
  mut item : Json?
}

///|
fn compact_v2_parse_failure(
  stage : String,
  category : String,
) -> @posoco.ModelError {
  @posoco.ModelError::ResponseParse(
    "OpenAI compact V2 failure (stage=\{stage}, category=\{category})",
  )
}

///|
/// Only output_item.done supplies the durable opaque item. completed.output,
/// text deltas and [DONE] cannot substitute for the V2 terminal contract.
fn CompactV2Stream::event(
  self : CompactV2Stream,
  payload : String,
) -> Bool raise @posoco.ModelError {
  let json = @json.parse(payload) catch {
    _ => raise compact_v2_parse_failure("json", "invalid_json")
  }
  guard json is Json::Object(fields) else {
    raise compact_v2_parse_failure("event", "not_object")
  }
  match fields.get("type") {
    Some(Json::String("response.output_item.done")) => {
      guard fields.get("item") is Some(Json::Object(item)) else {
        raise compact_v2_parse_failure("output_item", "missing")
      }
      match item.get("type") {
        Some(Json::String("compaction" | "compaction_summary")) => {
          guard item.get("encrypted_content") is Some(Json::String(_)) else {
            raise compact_v2_parse_failure(
              "compaction", "missing_encrypted_content",
            )
          }
          self.compaction_count += 1
          self.item = Some(json_deep_copy(Json::object(item)))
        }
        Some(Json::String(_)) => ()
        _ => raise compact_v2_parse_failure("output_item", "missing_type")
      }
      false
    }
    Some(Json::String("response.completed")) => {
      guard fields.get("response") is Some(Json::Object(response)) else {
        raise compact_v2_parse_failure("completed", "missing_response")
      }
      guard response.get("id") is Some(Json::String(id)) && !id.is_empty() else {
        raise compact_v2_parse_failure("completed", "missing_id")
      }
      if self.compaction_count != 1 {
        raise compact_v2_parse_failure("output", "compaction_count")
      }
      true
    }
    Some(Json::String("response.failed" | "response.incomplete" | "error")) =>
      raise compact_v2_parse_failure("terminal", "provider_error")
    Some(Json::String(_)) => false
    _ => raise compact_v2_parse_failure("event", "missing_type")
  }
}

///|
async fn OpenAIModelPort::compact_v2_stream(
  self : OpenAIModelPort,
  body : Json,
  session_id : String,
) -> Json raise @posoco.ModelError {
  let headers = build_headers(self.config, Some(session_id), true)
  let (origin, prefix) = split_openai_base_url(self.config.base_url)
  let client = @http.Client::Client(origin, headers~) catch {
    _ =>
      raise @posoco.ModelError::Transport(
        "OpenAI compact transport failure (stage=create_client)",
      )
  }
  defer client.close()
  let response = client.post(prefix + "/responses", body.stringify()) catch {
    _ =>
      raise @posoco.ModelError::Transport(
        "OpenAI compact transport failure (stage=send_request)",
      )
  }
  match self.quota_tracker {
    Some(tracker) => tracker.capture(response.headers)
    None => ()
  }
  if !is_openai_http_success(response.code) {
    let (summary, text) = read_error_body_summary(client) catch {
      _ => (BodyReadFailed, None)
    }
    match
      openai_quota_verdict(
        response.code,
        text,
        response.headers.get("Retry-After"),
        now_ms=@async.now(),
      ) {
      Some(@posoco.ModelError::RateLimited(info)) =>
        raise @posoco.ModelError::RateLimited({
          ..info,
          message: "OpenAI compact rate limited (stage=compact_http_status, status=429)",
          provider_code: match info.provider_code {
            Some(code) => compact_error_meta_value(Json::string(code))
            None => None
          },
        })
      Some(err) => raise err
      None => ()
    }
    raise @posoco.ModelError::Transport(
      format_compact_http_error(
        response.code,
        summary,
        text,
        response.headers.get("x-request-id"),
        endpoint_kind=if self.config.base_url == codex_oauth_api_base() {
          "codex_oauth"
        } else {
          "api_key"
        },
        model=self.config.model,
      ),
    )
  }
  let state = CompactV2Stream::{ compaction_count: 0, item: None, }
  let data : Array[String] = []
  let mut last_yield = @async.now()
  while true {
    let line = client.read_until("\n") catch {
      _ =>
        raise @posoco.ModelError::Transport(
          "OpenAI compact transport failure (stage=read_stream)",
        )
    }
    guard line is Some(line) else {
      raise compact_v2_parse_failure("terminal", "missing_completed")
    }
    let line = line.trim_end(chars="\r\n")
    if line.is_empty() {
      if !data.is_empty() {
        let payload = data.join("\n")
        data.clear()
        if payload == "[DONE]" {
          raise compact_v2_parse_failure("terminal", "missing_completed")
        }
        if state.event(payload) {
          guard state.item is Some(item) else {
            abort("validated compaction count")
          }
          return item
        }
      }
    } else if line.has_prefix("data:") {
      let value = line[5:]
      data.push(
        if value.has_prefix(" ") {
          value[1:].to_owned()
        } else {
          value.to_owned()
        },
      )
    }
    let now = @async.now()
    if now - last_yield >= 16L {
      @async.pause()
      last_yield = now
    }
  }
  raise compact_v2_parse_failure("terminal", "missing_completed")
}

///|
pub impl @posoco.ModelPort for OpenAIModelPort with fn compact(
  self : OpenAIModelPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  validate_openai_config(self.config)
  let session_id = scope.session_id.to_string()
  let (body, history) = build_compact_v2_request(
    self.config,
    messages.to_owned(),
    tools,
    options,
    session_id,
  )
  let item = self.compact_v2_stream(body, session_id)
  let retained = compact_v2_retained_history(history)
  retained.push(item)
  @posoco.CompactResult::{
    compacted_messages: compact_latest_window(retained),
    mode: @posoco.CompactMode::Replace,
  }
}
