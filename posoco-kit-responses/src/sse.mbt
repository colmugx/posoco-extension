///|
/// Pure classification for stream termination; used by the HTTP loop and
/// offline tests so EOF is never inferred from accumulated content.
/// (Transport failures raise `ModelError::Transport` directly at the read
/// site so the underlying error detail is preserved.)
pub(all) enum StreamTermination {
  ExplicitTerminal
  CleanEof
}

///|
pub fn classify_stream_termination(
  provider~ : String,
  termination : StreamTermination,
) -> @posoco.ModelError? {
  match termination {
    ExplicitTerminal => None
    CleanEof =>
      Some(
        @posoco.ModelError::ResponseParse(
          "\{provider} SSE truncated (stage=eof, terminal_marker=missing)",
        ),
      )
  }
}

///|
/// Use the canonical accumulator projection while retaining the provider
/// boundary in parse diagnostics. Other ModelError variants are propagated
/// unchanged so adapters never turn a typed failure into a parse error.
pub fn responses_stream_completion(
  provider~ : String,
  acc : @posoco.StreamAccumulator,
) -> @posoco.Completion raise @posoco.ModelError {
  let completion = acc.to_completion() catch {
    @posoco.ModelError::ResponseParse(message) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=tool_calls): " + message,
      )
    error => raise error
  }
  completion
}

///|
/// Reject incomplete streamed tool calls via the canonical accumulator
/// projection before the adapter assembles its final completion.
pub fn validate_stream_tool_calls(
  provider~ : String,
  acc : @posoco.StreamAccumulator,
) -> Unit raise @posoco.ModelError {
  let _ = responses_stream_completion(provider~, acc)
}

///|
/// Mutable collector for one streamed response: reasoning items captured for
/// verbatim replay (raw items with encrypted_content ride `Reasoning.raw` on
/// the final completion) plus the concatenated summary text fallback, and the
/// wire `output_index` → compact tool-call slot map. The Codex backend
/// interleaves non-tool output items (reasoning first on effort-tuned
/// requests), so the wire index of the first function call is not 0; the
/// accumulator contract requires a contiguous 0-based sequence over tool
/// calls, hence the remap.
pub(all) struct SseStreamState {
  items : Array[Json]
  mut summary : String
  tool_slots : Map[Int, Int]
}

///|
pub fn SseStreamState::SseStreamState() -> SseStreamState {
  { items: [], summary: "", tool_slots: Map::from_array([]), }
}

///|
/// Compact slot for one wire output index, allocating the next slot on first
/// sight. Added events arrive before their deltas, so allocation order
/// follows the stream.
fn SseStreamState::tool_slot(self : SseStreamState, wire_index : Int) -> Int {
  match self.tool_slots.get(wire_index) {
    Some(slot) => slot
    None => {
      let slot = self.tool_slots.length()
      self.tool_slots[wire_index] = slot
      slot
    }
  }
}

///|
/// Parse an SSE event data string into StreamChunk(s) and feed to accumulator.
/// Returns true when the stream is finished (response.completed seen).
pub fn process_responses_sse(
  provider~ : String,
  data : String,
  acc : @posoco.StreamAccumulator,
  on_chunk : (@posoco.StreamChunk) -> Unit,
  state? : SseStreamState = SseStreamState::SseStreamState(),
) -> Bool raise @posoco.ModelError {
  let event_json : Json = @json.parse(data) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=json, payload_chars=\{data.length()})",
      )
  }
  let event_map = match event_json {
    Json::Object(map) => map
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=event, category=not_object)",
      )
  }
  // A bare {"error": ...} data line carries no type key; it is a mid-stream
  // provider failure, not an event missing its type (aligned with the
  // chat-completions tolerance). Only bounded, enum-like labels (type/code)
  // cross into the message — free-text fields never do.
  match event_map.get("error") {
    Some(Json::Object(err)) =>
      raise @posoco.ModelError::Transport(
        "\{provider} SSE terminal failure (stage=error, category=provider_error\{extract_error_labels(err)})",
      )
    Some(Json::Null) | None => ()
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=error, category=wrong_type)",
      )
  }
  let event_type = match event_map.get("type") {
    Some(Json::String(s)) => s
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=event_type, category=wrong_type)",
      )
    None =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=event_type, category=missing)",
      )
  }
  match event_type {
    "response.output_text.delta" => {
      // Explicit "delta": null carries no content; skip the event. A missing
      // delta key stays loud inside extract_sse_string_field.
      match extract_sse_string_field(provider, event_json, "delta") {
        Some(token) => {
          let chunk = @posoco.StreamChunk::TextDelta(token~)
          on_chunk(chunk)
          acc.push(chunk)
        }
        None => ()
      }
      false
    }
    // Reasoning arrives through two official delta events (summary text, raw
    // reasoning text), both mapped onto the one ReasoningDelta chunk; summary
    // parts separate with a blank line, so part.done emits the separator.
    // The paired done/added events carry no incremental text. There is no
    // `response.reasoning.delta` event in the Responses API vocabulary.
    "response.reasoning_summary_text.delta" | "response.reasoning_text.delta" => {
      match extract_sse_string_field(provider, event_json, "delta") {
        Some(token) => {
          let chunk = @posoco.StreamChunk::ReasoningDelta(token~)
          on_chunk(chunk)
          acc.push(chunk)
        }
        None => ()
      }
      false
    }
    "response.reasoning_summary_part.done" => {
      let chunk = @posoco.StreamChunk::ReasoningDelta(token="\n\n")
      on_chunk(chunk)
      acc.push(chunk)
      false
    }
    "response.reasoning_summary_part.added"
    | "response.reasoning_summary_text.done"
    | "response.reasoning_text.done" => false
    "response.function_call_arguments.delta" => {
      match extract_sse_string_field(provider, event_json, "delta") {
        Some(delta) => {
          let wire_index = extract_sse_int_field(
            provider, event_json, "output_index",
          )
          let chunk = @posoco.StreamChunk::ToolCallDelta(
            index=state.tool_slot(wire_index),
            id=None,
            name=None,
            arguments_delta=Some(delta),
          )
          on_chunk(chunk)
          acc.push(chunk)
        }
        None => ()
      }
      false
    }
    "response.output_item.added" => {
      match extract_sse_output_item(provider, event_json) {
        Some((wire_index, fc_id, fc_name)) => {
          let chunk = @posoco.StreamChunk::ToolCallDelta(
            index=state.tool_slot(wire_index),
            id=Some(fc_id),
            name=Some(fc_name),
            arguments_delta=None,
          )
          on_chunk(chunk)
          acc.push(chunk)
        }
        None => capture_reasoning_item(event_json, state)
      }
      false
    }
    // Identity backstop: the done event repeats the full item (call_id, name,
    // and for reasoning items the encrypted_content). If the added event was
    // missed, this still fills the builder identity; reasoning items are only
    // complete at done (encrypted_content grows during the stream).
    "response.output_item.done" => {
      match extract_sse_output_item(provider, event_json) {
        Some((wire_index, fc_id, fc_name)) => {
          let chunk = @posoco.StreamChunk::ToolCallDelta(
            index=state.tool_slot(wire_index),
            id=Some(fc_id),
            name=Some(fc_name),
            arguments_delta=None,
          )
          on_chunk(chunk)
          acc.push(chunk)
        }
        None => capture_reasoning_item(event_json, state)
      }
      false
    }
    "response.completed" => {
      let response_json = extract_sse_response(
        provider, event_json, "completed",
      )
      validate_terminal_response(provider~, response_json, "completed.")
      // Capture reasoning items for verbatim replay (official manual state
      // management); they ride on the final completion via Reasoning.raw. The
      // Codex backend ships `output: []` on the terminal event, so this
      // typically captures nothing — the real items arrive via
      // output_item.added/done and are captured there.
      match response_json {
        Json::Object(rmap) =>
          match rmap.get("output") {
            Some(Json::Array(_) as out) => {
              let (raw_items, summary) = extract_reasoning_items(provider~, out)
              for item in raw_items {
                state.items.push(item)
              }
              if raw_items.length() > 0 {
                state.summary = summary
              }
            }
            _ => ()
          }
        _ => ()
      }
      match extract_usage(provider~, response_json) {
        Some(usage) => {
          let usage_chunk = @posoco.StreamChunk::Usage(
            input_tokens=usage.input_tokens.unwrap_or(0),
            output_tokens=usage.output_tokens.unwrap_or(0),
            total_tokens=usage.total_tokens.unwrap_or(0),
            cached_input_tokens=usage.cached_input_tokens,
            uncached_input_tokens=usage.uncached_input_tokens,
          )
          on_chunk(usage_chunk)
          acc.push(usage_chunk)
        }
        None => ()
      }
      let declared = extract_finish_from_completed(provider, response_json)
      let completion = responses_stream_completion(provider~, acc)
      if declared is @posoco.FinishReason::ToolCalls &&
        !completion.has_tool_calls() {
        raise @posoco.ModelError::ResponseParse(
          "\{provider} SSE parse failure (stage=tool.events, category=missing)",
        )
      }
      // The Codex terminal event carries an empty output array, so the
      // declared reason cannot be trusted alone: tool calls that streamed are
      // the authoritative ToolCalls signal.
      let reason = if !completion.has_tool_calls() {
        declared
      } else {
        @posoco.FinishReason::ToolCalls
      }
      let finish_chunk = @posoco.StreamChunk::Finish(
        reason=finish_reason_wire_string(reason),
      )
      on_chunk(finish_chunk)
      acc.push(finish_chunk)
      true
    }
    // Terminal provider failures are Transport errors, not parse errors
    // (same classification as a non-stream {"error": ...} body); the message
    // stays payload-free.
    "response.failed" =>
      raise @posoco.ModelError::Transport(
        "\{provider} SSE terminal failure (stage=response.failed, category=provider_error)",
      )
    "response.incomplete" =>
      raise @posoco.ModelError::Transport(
        "\{provider} SSE terminal failure (stage=response.incomplete, category=not_completed)",
      )
    "error" =>
      raise @posoco.ModelError::Transport(
        "\{provider} SSE terminal failure (stage=error, category=provider_error)",
      )
    _ => false
  }
}

///|
/// Capture a reasoning output item verbatim from an added/done event. The raw
/// item (including encrypted_content) is what later requests must replay; it
/// is only re-serialized by the provider, never by us.
fn capture_reasoning_item(event_json : Json, state : SseStreamState) -> Unit {
  match event_json {
    Json::Object(map) =>
      match map.get("item") {
        Some(Json::Object(item_map) as item) =>
          match item_map.get("type") {
            Some(Json::String("reasoning")) => {
              // Done replaces the added snapshot: the item is only complete
              // (full encrypted_content) at done.
              state.items.retain(fn(existing) {
                match existing {
                  Json::Object(existing_map) =>
                    existing_map.get("id") != item_map.get("id")
                  _ => true
                }
              })
              state.items.push(item)
            }
            _ => ()
          }
        _ => ()
      }
    _ => ()
  }
}

///|
/// The accumulator's Finish chunk carries the provider wire spelling
/// (lowercase "stop"/"tool_calls"), not the variant Show form — the
/// completion parser matches the wire spelling.
fn finish_reason_wire_string(reason : @posoco.FinishReason) -> String {
  match reason {
    Stop => "stop"
    Length => "length"
    ToolCalls => "tool_calls"
    Other(label) => label
  }
}

///|
/// Extract the nested response object from a terminal SSE event.
fn extract_sse_response(
  provider : String,
  event_json : Json,
  event_stage : String,
) -> Json raise @posoco.ModelError {
  match event_json {
    Json::Object(map) =>
      match map.get("response") {
        Some(Json::Object(_) as response) => response
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=\{event_stage}.response, category=wrong_type)",
          )
        None =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=\{event_stage}.response, category=missing)",
          )
      }
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=\{event_stage}, category=not_object)",
      )
  }
}

///|
/// Extract FinishReason from a validated completed response object.
fn extract_finish_from_completed(
  provider : String,
  response_json : Json,
) -> @posoco.FinishReason raise @posoco.ModelError {
  let response_obj = match response_json {
    Json::Object(map) => map
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=completed.response, category=not_object)",
      )
  }
  // A missing or explicit-null output carries no tool calls; treat it as an
  // empty array (FinishReason::Stop) instead of failing the stream.
  let has_fc = match response_obj.get("output") {
    Some(Json::Array(arr)) => {
      let (_, has_fc) = extract_tool_calls(provider~, Json::array(arr))
      has_fc
    }
    Some(Json::Null) | None => false
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=completed.output, category=wrong_type)",
      )
  }
  if has_fc {
    @posoco.FinishReason::ToolCalls
  } else {
    @posoco.FinishReason::Stop
  }
}

///|
/// Extract a required string field from an SSE event object. A missing key is
/// loud; an explicit null is treated as absent (returns None) so the caller
/// can skip a content-free event, mirroring the chat-completions tolerance.
fn extract_sse_string_field(
  provider : String,
  json : Json,
  field : String,
) -> String? raise @posoco.ModelError {
  match json {
    Json::Object(map) =>
      match map.get(field) {
        Some(Json::String(s)) => Some(s)
        Some(Json::Null) => None
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=\{field}, category=wrong_type)",
          )
        None =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=\{field}, category=missing)",
          )
      }
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=\{field}, category=not_object)",
      )
  }
}

///|
fn extract_sse_int_field(
  provider : String,
  json : Json,
  field : String,
) -> Int raise @posoco.ModelError {
  match json {
    Json::Object(map) =>
      match map.get(field) {
        Some(Json::Number(n, ..)) => n.to_int()
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=\{field}, category=wrong_type)",
          )
        None =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=\{field}, category=missing)",
          )
      }
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=\{field}, category=not_object)",
      )
  }
}

///|
/// Extract output item info (index, id, name) from output_item.added/done
/// events.
fn extract_sse_output_item(
  provider : String,
  json : Json,
) -> (Int, String, String)? raise @posoco.ModelError {
  match json {
    Json::Object(map) =>
      match map.get("item") {
        Some(Json::Object(item_map)) =>
          match item_map.get("type") {
            Some(Json::String("function_call")) => {
              let idx = extract_sse_int_field(provider, json, "output_index")
              let fc_id = match item_map.get("call_id") {
                Some(Json::String(s)) if s != "" => s
                Some(Json::String(_)) =>
                  raise @posoco.ModelError::ResponseParse(
                    "\{provider} SSE parse failure (stage=tool.call_id, category=empty)",
                  )
                // Explicit "call_id": null = absent; fall back to the item id
                // (some providers serialize call_id as null on added events).
                Some(Json::Null) | None =>
                  match item_map.get("id") {
                    Some(Json::String(s)) if s != "" => s
                    Some(Json::String(_)) =>
                      raise @posoco.ModelError::ResponseParse(
                        "\{provider} SSE parse failure (stage=tool.id, category=empty)",
                      )
                    Some(_) =>
                      raise @posoco.ModelError::ResponseParse(
                        "\{provider} SSE parse failure (stage=tool.id, category=wrong_type)",
                      )
                    None =>
                      raise @posoco.ModelError::ResponseParse(
                        "\{provider} SSE parse failure (stage=tool.id, category=missing)",
                      )
                  }
                Some(_) =>
                  raise @posoco.ModelError::ResponseParse(
                    "\{provider} SSE parse failure (stage=tool.call_id, category=wrong_type)",
                  )
              }
              let fc_name = match item_map.get("name") {
                Some(Json::String(s)) if s != "" => s
                Some(Json::String(_)) =>
                  raise @posoco.ModelError::ResponseParse(
                    "\{provider} SSE parse failure (stage=tool.name, category=empty)",
                  )
                Some(Json::Null) =>
                  raise @posoco.ModelError::ResponseParse(
                    "\{provider} SSE parse failure (stage=tool.name, category=missing)",
                  )
                Some(_) =>
                  raise @posoco.ModelError::ResponseParse(
                    "\{provider} SSE parse failure (stage=tool.name, category=wrong_type)",
                  )
                None =>
                  raise @posoco.ModelError::ResponseParse(
                    "\{provider} SSE parse failure (stage=tool.name, category=missing)",
                  )
              }
              Some((idx, fc_id, fc_name))
            }
            Some(Json::String(_)) => None
            Some(Json::Null) =>
              raise @posoco.ModelError::ResponseParse(
                "\{provider} SSE parse failure (stage=item.type, category=missing)",
              )
            Some(_) =>
              raise @posoco.ModelError::ResponseParse(
                "\{provider} SSE parse failure (stage=item.type, category=wrong_type)",
              )
            None =>
              raise @posoco.ModelError::ResponseParse(
                "\{provider} SSE parse failure (stage=item.type, category=missing)",
              )
          }
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=item, category=wrong_type)",
          )
        None =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=item, category=missing)",
          )
      }
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=event, category=not_object)",
      )
  }
}

///|
/// Bounded, enum-like error metadata from a provider error object. Only
/// `type` and `code` may cross into the failure message, and only when they
/// are short charset-bounded labels (so no prompt/request text can ride
/// along). Returns "" or e.g. ", error_type=server_error, error_code=402".
fn extract_error_labels(err : Map[String, Json]) -> String {
  let buf = StringBuilder()
  match err.get("type") {
    Some(Json::String(t)) =>
      match sanitize_error_label(t) {
        Some(label) => {
          buf.write_string(", error_type=")
          buf.write_string(label)
        }
        None => ()
      }
    _ => ()
  }
  match err.get("code") {
    Some(Json::String(c)) =>
      match sanitize_error_label(c) {
        Some(label) => {
          buf.write_string(", error_code=")
          buf.write_string(label)
        }
        None => ()
      }
    Some(Json::Number(n, ..)) => {
      buf.write_string(", error_code=")
      buf.write_string(n.to_int().to_string())
    }
    _ => ()
  }
  buf.to_string()
}

///|
/// A label is safe to surface when it is short and enum-like: ASCII
/// alphanumerics plus `_`, `-`, `.`, `/`, at most 64 chars. Anything else
/// (spaces included) is treated as free text and dropped.
fn sanitize_error_label(value : String) -> String? {
  if value.length() == 0 || value.length() > 64 {
    return None
  }
  for c in value {
    let ok = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '_' ||
      c == '-' ||
      c == '.' ||
      c == '/'
    if !ok {
      return None
    }
  }
  Some(value)
}
