///|
/// Own SSE streaming parser for OpenRouter chat completions.
///
/// The shared kit parser (posoco-kit-chat-completions) only recognizes
/// `delta.reasoning_content`; OpenRouter streams reasoning as `delta.reasoning`
/// (string increments) plus `delta.reasoning_details` (structured fragments
/// arriving piecewise). Dropping either silently would break chain-of-thought
/// replay for encrypted-block models, so this endpoint carries its own
/// processor, structurally modeled on the kit parser: data payloads only,
/// Bool termination, the same stage=/category= failure vocabulary, tool-call
/// stitching and usage extraction with identical semantics.
///
/// Wire facts encoded here:
/// - `delta.reasoning` string increments map to `ReasoningDelta`.
/// - Each chunk's `delta.reasoning_details` array is an incremental fragment;
///   arrays are appended verbatim (order preserved, elements never
///   interpreted) and replayed whole as `Reasoning.raw`.
/// - A chunk may carry a top-level `error` object even under HTTP 200 — that
///   is a provider failure surfaced as Transport, never a parse failure.
/// - Usage rides the final chunk automatically (`stream_options.include_usage`
///   is deprecated); the usage chunk usually has an empty `choices` array and
///   must not terminate the stream — only [DONE]/finish_reason do. Missing
///   token fields are tolerated: usage is automatic, never contractually
///   required per chunk.
///
/// Why a wrapper state instead of a bare StreamAccumulator:
/// `StreamAccumulator::to_completion` hardcodes `Reasoning.raw = None` and
/// offers no custom-raw hook, so accumulated `reasoning_details` cannot ride
/// through it. `OpenRouterStreamState` therefore bundles the standard
/// accumulator with the details array; its `to_completion()` first delegates
/// to `acc.to_completion()` (text / tool calls / usage / finish untouched),
/// then fills `Reasoning.raw` with the details array while keeping any
/// streamed reasoning text as `content` (a details-only stream degrades to
/// content="", mirroring the non-streaming decoder). This is the smallest
/// shape for the stage-5 chat driver: one handle in, one completion out.
///
/// Termination semantics vs the kit parser: like the kit, this returns true
/// on a finish_reason chunk or on [DONE]. Unlike OpenAI, OpenRouter trails
/// the auto-attached usage chunk and heartbeat comments AFTER the
/// finish_reason chunk, so the driver should keep draining buffered payloads
/// until [DONE] rather than hard-breaking on the first true. To keep that
/// draining safe, a [DONE] arriving after an earlier finish_reason chunk
/// emits nothing — the recorded Finish (e.g. tool_calls) must not be
/// clobbered back to "stop" by the marker.

///|
priv struct OpenRouterStreamState {
  acc : @posoco.StreamAccumulator
  details : Array[Json]
  mut terminated : Bool
}

///|
fn OpenRouterStreamState::OpenRouterStreamState() -> OpenRouterStreamState {
  {
    acc: @posoco.StreamAccumulator::StreamAccumulator(),
    details: [],
    terminated: false,
  }
}

///|
/// Assemble the stream into a canonical Completion. Delegates the standard
/// accumulation to StreamAccumulator, then overlays the verbatim
/// `reasoning_details` array onto Reasoning.raw without touching content,
/// tool calls, finish reason, or usage.
fn OpenRouterStreamState::to_completion(
  self : OpenRouterStreamState,
) -> @posoco.Completion raise @posoco.ModelError {
  let completion = self.acc.to_completion()
  if self.details.length() == 0 {
    return completion
  }
  let raw : Json = Json::array(self.details)
  let payload = completion.message
  let reasoning = match payload.reasoning {
    Some(r) => Some(@posoco.Reasoning::{ content: r.content, raw: Some(raw) })
    None =>
      // Details arrived without any `reasoning` string increment. The
      // details themselves are what must replay; stitching display text out
      // of them would risk reordering encrypted blocks — content stays "".
      Some(@posoco.Reasoning::{ content: "", raw: Some(raw) })
  }
  @posoco.Completion::Completion(
    content=payload.content,
    tool_calls=payload.tool_calls,
    reasoning~,
    finish_reason=payload.finish_reason,
    usage=completion.usage,
  )
}

///|
/// Parse one SSE data payload into StreamChunk(s) and feed the state.
/// Returns true when the stream is finished ([DONE] or finish_reason present).
/// The caller supplies payloads already stripped of the "data:" prefix; the
/// `on_chunk` callback receives every chunk twice-consumed style (callback
/// for telemetry, accumulator for the final completion).
fn process_openrouter_sse(
  payload : String,
  state : OpenRouterStreamState,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> Bool raise @posoco.ModelError {
  // Heartbeat comment lines (`: OPENROUTER PROCESSING`) are dropped by the
  // chat driver's read loop, which forwards only "data:"-prefixed lines.
  // The guard is defense-in-depth: a stray comment carries no stream bytes,
  // so skipping it silently can never lose content.
  if payload.has_prefix(":") {
    return false
  }
  if payload == "[DONE]" {
    // A second terminal after an earlier finish_reason chunk (the normal
    // OpenRouter tail: finish chunk, trailing usage/comment lines, [DONE])
    // must not overwrite the recorded finish reason with "stop".
    if !state.terminated {
      let chunk = @posoco.StreamChunk::Finish(reason="stop")
      on_chunk(chunk)
      state.acc.push(chunk)
    }
    return true
  }
  let event_json : Json = @json.parse(payload) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "openrouter SSE parse failure (stage=json, payload_chars=\{payload.length()})",
      )
  }
  guard event_json is Object(root) else {
    raise @posoco.ModelError::ResponseParse(
      "openrouter SSE parse failure (stage=event, category=not_object)",
    )
  }
  // A structured error under HTTP 200 is a provider failure, not a malformed
  // chunk. Only the bounded, enum-like error_type label crosses into the
  // message; free text (message field) never does (error transparency).
  match root.get("error") {
    Some(Object(err)) =>
      raise @posoco.ModelError::Transport(
        "openrouter SSE stream failure (stage=error, category=provider_error\{extract_stream_error_labels(err)})",
      )
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "openrouter SSE parse failure (stage=error, category=wrong_type)",
      )
    None => ()
  }
  let choices = match root.get("choices") {
    Some(Array(choices)) => choices
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "openrouter SSE parse failure (stage=choices, category=wrong_type)",
      )
    None => {
      // A usage-only chunk is valid without choices; it never terminates.
      match root.get("usage") {
        Some(Object(_)) => push_usage_chunk(root, state, on_chunk)
        // Explicit "usage": null counts as absent; a chunk with neither
        // choices nor usage nor error is a content-free preamble — safe to
        // skip because stream integrity is enforced by [DONE]/finish_reason.
        Some(Null) | None => ()
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "openrouter SSE parse failure (stage=usage, category=wrong_type)",
          )
      }
      return false
    }
  }
  if choices.length() == 0 {
    // OpenRouter's trailing usage chunk carries an empty choices array; any
    // other empty-choices chunk is likewise content-free.
    match root.get("usage") {
      Some(Object(_)) => push_usage_chunk(root, state, on_chunk)
      Some(Null) | None => ()
      Some(_) =>
        raise @posoco.ModelError::ResponseParse(
          "openrouter SSE parse failure (stage=usage, category=wrong_type)",
        )
    }
    return false
  }
  guard choices[0] is Object(choice) else {
    raise @posoco.ModelError::ResponseParse(
      "openrouter SSE parse failure (stage=choice, category=not_object)",
    )
  }
  match choice.get("delta") {
    Some(Object(delta)) => {
      // Text content delta. An explicitly empty string carries no
      // information — some models attach `content: ""` to every reasoning
      // chunk, and emitting it as a text delta would make the host close the
      // live thinking block after each reasoning fragment.
      match delta.get("content") {
        Some(String(token)) if token.length() > 0 => {
          let chunk = @posoco.StreamChunk::TextDelta(token~)
          on_chunk(chunk)
          state.acc.push(chunk)
        }
        Some(String(_)) | Some(Null) | None => ()
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "openrouter SSE parse failure (stage=delta.content, category=wrong_type)",
          )
      }
      // Reasoning delta — OpenRouter spells it `reasoning` (never DeepSeek's
      // `reasoning_content`, which is deliberately unrecognized here). Empty
      // strings are skipped for the same reason as content.
      match delta.get("reasoning") {
        Some(String(token)) if token.length() > 0 => {
          let chunk = @posoco.StreamChunk::ReasoningDelta(token~)
          on_chunk(chunk)
          state.acc.push(chunk)
        }
        Some(String(_)) | Some(Null) | None => ()
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "openrouter SSE parse failure (stage=delta.reasoning, category=wrong_type)",
          )
      }
      // Structured reasoning fragments arrive piecewise; each chunk's array
      // is an increment. Elements are stored verbatim and never interpreted —
      // encrypted blocks must replay byte-exact and in order.
      match delta.get("reasoning_details") {
        Some(Array(frags)) =>
          for frag in frags {
            state.details.push(frag)
          }
        Some(Null) | None => ()
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "openrouter SSE parse failure (stage=delta.reasoning_details, category=wrong_type)",
          )
      }
      // Tool call deltas — stitching semantics identical to the kit parser.
      match delta.get("tool_calls") {
        Some(Array(tcs)) =>
          for tc in tcs {
            match tc {
              Object(o) => {
                let idx = match o.get("index") {
                  Some(Number(n, ..)) if n.to_int() >= 0 => n.to_int()
                  Some(Number(_, ..)) =>
                    raise @posoco.ModelError::ResponseParse(
                      "openrouter SSE parse failure (stage=tool.index, category=negative)",
                    )
                  Some(_) =>
                    raise @posoco.ModelError::ResponseParse(
                      "openrouter SSE parse failure (stage=tool.index, category=wrong_type)",
                    )
                  None =>
                    raise @posoco.ModelError::ResponseParse(
                      "openrouter SSE parse failure (stage=tool.index, category=missing)",
                    )
                }
                let id : String? = match o.get("id") {
                  Some(String(s)) if s != "" => Some(s)
                  Some(String(_)) =>
                    raise @posoco.ModelError::ResponseParse(
                      "openrouter SSE parse failure (stage=tool.id, category=empty)",
                    )
                  // Continuation chunks may serialize the absent id as
                  // explicit null; the accumulator merges by index.
                  Some(Null) | None => None
                  Some(_) =>
                    raise @posoco.ModelError::ResponseParse(
                      "openrouter SSE parse failure (stage=tool.id, category=wrong_type)",
                    )
                }
                let (name, args_delta) : (String?, String?) = match
                  o.get("function") {
                  Some(Object(f)) => {
                    let n : String? = match f.get("name") {
                      Some(String(s)) if s != "" => Some(s)
                      Some(String(_)) =>
                        raise @posoco.ModelError::ResponseParse(
                          "openrouter SSE parse failure (stage=tool.name, category=empty)",
                        )
                      Some(Null) | None => None
                      Some(_) =>
                        raise @posoco.ModelError::ResponseParse(
                          "openrouter SSE parse failure (stage=tool.name, category=wrong_type)",
                        )
                    }
                    let a : String? = match f.get("arguments") {
                      Some(String(s)) => Some(s)
                      Some(Null) | None => None
                      Some(_) =>
                        raise @posoco.ModelError::ResponseParse(
                          "openrouter SSE parse failure (stage=tool.arguments, category=wrong_type)",
                        )
                    }
                    if n is None && a is None {
                      raise @posoco.ModelError::ResponseParse(
                        "openrouter SSE parse failure (stage=tool.function, category=empty)",
                      )
                    }
                    (n, a)
                  }
                  Some(_) =>
                    raise @posoco.ModelError::ResponseParse(
                      "openrouter SSE parse failure (stage=tool.function, category=wrong_type)",
                    )
                  None =>
                    raise @posoco.ModelError::ResponseParse(
                      "openrouter SSE parse failure (stage=tool.function, category=missing)",
                    )
                }
                let chunk = @posoco.StreamChunk::ToolCallDelta(
                  index=idx,
                  id~,
                  name~,
                  arguments_delta=args_delta,
                )
                on_chunk(chunk)
                state.acc.push(chunk)
              }
              _ =>
                raise @posoco.ModelError::ResponseParse(
                  "openrouter SSE parse failure (stage=tool, category=not_object)",
                )
            }
          }
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "openrouter SSE parse failure (stage=delta.tool_calls, category=wrong_type)",
          )
        None => ()
      }
    }
    // A choice with neither delta nor finish_reason carries no content;
    // tolerate both a missing key and an explicit null.
    Some(Null) | None => ()
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "openrouter SSE parse failure (stage=delta, category=wrong_type)",
      )
  }
  // finish_reason rides the last choices-bearing chunk; usage may ride it too.
  // It is processed AFTER the delta: some models attach the final text or
  // reasoning fragment to the same chunk as the finish marker, and the delta
  // must not be dropped by an early terminal return.
  match choice.get("finish_reason") {
    Some(String(reason)) =>
      if reason != "" {
        match root.get("usage") {
          Some(Object(_)) => push_usage_chunk(root, state, on_chunk)
          Some(Null) | None => ()
          Some(_) =>
            raise @posoco.ModelError::ResponseParse(
              "openrouter SSE parse failure (stage=usage, category=wrong_type)",
            )
        }
        let chunk = @posoco.StreamChunk::Finish(reason~)
        on_chunk(chunk)
        state.acc.push(chunk)
        state.terminated = true
        return true
      } else {
        raise @posoco.ModelError::ResponseParse(
          "openrouter SSE parse failure (stage=finish_reason, category=empty)",
        )
      }
    Some(Null) | None => ()
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "openrouter SSE parse failure (stage=finish_reason, category=wrong_type)",
      )
  }
  false
}

///|
/// Extract the chunk's `usage` object into a Usage chunk and double-write it
/// (callback + accumulator). Token fields are automatic-attached facts, so a
/// missing field degrades to None (0 in the chunk) rather than failing.
fn push_usage_chunk(
  root : Map[String, Json],
  state : OpenRouterStreamState,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> Unit raise @posoco.ModelError {
  match root.get("usage") {
    Some(Object(u)) => {
      let prompt = match u.get("prompt_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "openrouter SSE parse failure (stage=usage.prompt_tokens, category=wrong_type)",
          )
        None => None
      }
      let comp = match u.get("completion_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "openrouter SSE parse failure (stage=usage.completion_tokens, category=wrong_type)",
          )
        None => None
      }
      let total = match u.get("total_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "openrouter SSE parse failure (stage=usage.total_tokens, category=wrong_type)",
          )
        None => None
      }
      let chunk = @posoco.StreamChunk::Usage(
        input_tokens=prompt.unwrap_or(0),
        output_tokens=comp.unwrap_or(0),
        total_tokens=total.unwrap_or(0),
        // Cache spellings reuse the kit helpers (OpenAI/DeepSeek/Moonshot/
        // Anthropic-gateway conventions).
        cached_input_tokens=@chatkit.cached_input_tokens_from_usage(u),
        uncached_input_tokens=@chatkit.uncached_input_tokens_from_usage(u),
      )
      on_chunk(chunk)
      state.acc.push(chunk)
    }
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "openrouter SSE parse failure (stage=usage, category=wrong_type)",
      )
    None =>
      raise @posoco.ModelError::ResponseParse(
        "openrouter SSE parse failure (stage=usage, category=missing)",
      )
  }
}

///|
/// Bounded error metadata from an OpenRouter error object
/// ({error:{code,message,metadata}}): only `metadata.error_type` may cross
/// into the failure message, and only when it is a short enum-like label
/// (so no prompt/request text can ride along). Returns "" or e.g.
/// ", error_type=rate_limit_exceeded".
fn extract_stream_error_labels(err : Map[String, Json]) -> String {
  match err.get("metadata") {
    Some(Object(metadata)) =>
      match metadata.get("error_type") {
        Some(String(t)) =>
          match sanitize_error_label(t) {
            Some(label) => ", error_type=\{label}"
            None => ""
          }
        _ => ""
      }
    _ => ""
  }
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
