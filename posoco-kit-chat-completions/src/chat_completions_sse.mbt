///|
/// Shared SSE streaming parser for OpenAI Chat Completions–style providers.
///
/// This is the single implementation behind the streaming ModelPorts of the
/// provider adaptors built on it; each extension delegates with its own
/// `provider~` prefix so error messages stay provider-labeled. Fix tolerance
/// bugs here once, not once per adaptor.
///
/// OpenAI Chat Completions SSE event format:
///   data: {"choices":[{"delta":{"content":"..."},"finish_reason":null}]}
///   data: {"choices":[{"delta":{"reasoning_content":"..."},"finish_reason":null}]}
///   data: {"choices":[{"delta":{"tool_calls":[...]}}]}
///   data: {"choices":[{"finish_reason":"stop"}],"usage":{...}}
///   data: [DONE]
///
/// `reasoning_content` deltas are tolerated (some compatible servers emit
/// them) and surfaced as `ReasoningDelta`; servers that never emit them simply
/// produce a text-only stream.
///
/// Tolerance policy for real-world server variation:
/// - An absent optional field serialized as explicit null is treated as
///   absent (tool-call id/name/arguments, delta, usage).
/// - Content-free chunks are skipped: no choices/usage/error keys, an empty
///   choices array (with usage still extracted when present), or a choice
///   with neither delta nor finish_reason.
/// - A mid-stream {"error": ...} object is a provider failure surfaced under
///   stage=error, never reported as a malformed chunk.
/// - Genuinely wrong shapes (wrong types, empty required strings, negative
///   index) stay loud parse failures.

///|
/// Parse one SSE data line into StreamChunk(s) and feed to accumulator.
/// Returns true when the stream is finished ([DONE] or finish_reason present).
/// `provider~` labels every raised message (e.g. "openai-compatible",
/// "DeepSeek", "kimi"). `usage_fields_required~` selects the streamed-usage
/// policy: DeepSeek/kimi require every token field (loud on missing), the
/// generic compatible adapter maps missing fields to None.
pub fn process_chat_completions_sse(
  provider~ : String,
  usage_fields_required? : Bool = false,
  data : String,
  acc : @posoco.StreamAccumulator,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> Bool raise @posoco.ModelError {
  // [DONE] marker — end of stream
  if data == "[DONE]" {
    let chunk = @posoco.StreamChunk::Finish(reason="stop")
    on_chunk(chunk)
    acc.push(chunk)
    return true
  }
  let event_json : Json = @json.parse(data) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=json, payload_chars=\{data.length()})",
      )
  }
  guard event_json is Object(root) else {
    raise @posoco.ModelError::ResponseParse(
      "\{provider} SSE parse failure (stage=event, category=not_object)",
    )
  }
  // A mid-stream structured error is a provider failure, not a malformed
  // chunk: surface it under its own stage instead of "choices missing".
  // Only bounded, enum-like labels (type/code) cross into the message —
  // free-text fields (message/param) never do (error transparency).
  match root.get("error") {
    Some(Object(err)) =>
      raise @posoco.ModelError::Transport(
        "\{provider} SSE stream failure (stage=error, category=provider_error\{extract_error_labels(err)})",
      )
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=error, category=wrong_type)",
      )
    None => ()
  }
  let choices = match root.get("choices") {
    Some(Array(choices)) => choices
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=choices, category=wrong_type)",
      )
    None => {
      // A usage-only chunk is valid without choices.
      match root.get("usage") {
        Some(Object(_)) => {
          let usage = extract_stream_usage(
            provider,
            root,
            usage_fields_required~,
          )
          let chunk = @posoco.StreamChunk::Usage(
            input_tokens=usage.input_tokens.unwrap_or(0),
            output_tokens=usage.output_tokens.unwrap_or(0),
            total_tokens=usage.total_tokens.unwrap_or(0),
            cached_input_tokens=usage.cached_input_tokens,
            uncached_input_tokens=usage.uncached_input_tokens,
          )
          on_chunk(chunk)
          acc.push(chunk)
        }
        // Explicit "usage": null = absent (some gateways put it on every
        // chunk); with no choices either, the chunk is content-free — a
        // preamble or keepalive. Skipping is safe: stream integrity is
        // enforced by the terminal marker ([DONE]/finish_reason) plus the
        // EOF truncation check, not by chunk shape.
        Some(Null) | None => ()
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=usage, category=wrong_type)",
          )
      }
      return false
    }
  }
  if choices.length() == 0 {
    // With stream_options.include_usage the usage chunk carries an empty
    // choices array; any other empty-choices chunk is likewise content-free.
    match root.get("usage") {
      Some(Object(_)) => {
        let usage = extract_stream_usage(provider, root, usage_fields_required~)
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
      Some(Null) | None => ()
      Some(_) =>
        raise @posoco.ModelError::ResponseParse(
          "\{provider} SSE parse failure (stage=usage, category=wrong_type)",
        )
    }
    return false
  }
  guard choices[0] is Object(choice) else {
    raise @posoco.ModelError::ResponseParse(
      "\{provider} SSE parse failure (stage=choice, category=not_object)",
    )
  }
  match choice.get("finish_reason") {
    Some(String(reason)) =>
      if reason != "" {
        match root.get("usage") {
          Some(Object(_)) => {
            let usage = extract_stream_usage(
              provider,
              root,
              usage_fields_required~,
            )
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
          // Explicit "usage": null on the finish chunk = no usage reported.
          Some(Null) | None => ()
          Some(_) =>
            raise @posoco.ModelError::ResponseParse(
              "\{provider} SSE parse failure (stage=usage, category=wrong_type)",
            )
        }
        let chunk = @posoco.StreamChunk::Finish(reason~)
        on_chunk(chunk)
        acc.push(chunk)
        return true
      } else {
        raise @posoco.ModelError::ResponseParse(
          "\{provider} SSE parse failure (stage=finish_reason, category=empty)",
        )
      }
    Some(Null) | None => ()
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=finish_reason, category=wrong_type)",
      )
  }
  match choice.get("delta") {
    Some(Object(delta)) => {
      // Text content delta
      match delta.get("content") {
        Some(String(token)) => {
          let chunk = @posoco.StreamChunk::TextDelta(token~)
          on_chunk(chunk)
          acc.push(chunk)
        }
        Some(Null) | None => ()
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=delta.content, category=wrong_type)",
          )
      }
      // Reasoning content delta (optional; some compatible servers emit it)
      match delta.get("reasoning_content") {
        Some(String(token)) => {
          let chunk = @posoco.StreamChunk::ReasoningDelta(token~)
          on_chunk(chunk)
          acc.push(chunk)
        }
        Some(Null) | None => ()
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=delta.reasoning_content, category=wrong_type)",
          )
      }
      // Tool call deltas
      match delta.get("tool_calls") {
        Some(Array(tcs)) =>
          for tc in tcs {
            match tc {
              Object(o) => {
                let idx = match o.get("index") {
                  Some(Number(n, ..)) if n.to_int() >= 0 => n.to_int()
                  Some(Number(_, ..)) =>
                    raise @posoco.ModelError::ResponseParse(
                      "\{provider} SSE parse failure (stage=tool.index, category=negative)",
                    )
                  Some(_) =>
                    raise @posoco.ModelError::ResponseParse(
                      "\{provider} SSE parse failure (stage=tool.index, category=wrong_type)",
                    )
                  None =>
                    raise @posoco.ModelError::ResponseParse(
                      "\{provider} SSE parse failure (stage=tool.index, category=missing)",
                    )
                }
                let id : String? = match o.get("id") {
                  Some(String(s)) if s != "" => Some(s)
                  Some(String(_)) =>
                    raise @posoco.ModelError::ResponseParse(
                      "\{provider} SSE parse failure (stage=tool.id, category=empty)",
                    )
                  // Some compatible servers serialize the absent id of a
                  // continuation chunk as explicit "id": null; treat null
                  // like a missing key (the accumulator merges by index).
                  Some(Null) | None => None
                  Some(_) =>
                    raise @posoco.ModelError::ResponseParse(
                      "\{provider} SSE parse failure (stage=tool.id, category=wrong_type)",
                    )
                }
                let (name, args_delta) : (String?, String?) = match
                  o.get("function") {
                  Some(Object(f)) => {
                    let n : String? = match f.get("name") {
                      Some(String(s)) if s != "" => Some(s)
                      Some(String(_)) =>
                        raise @posoco.ModelError::ResponseParse(
                          "\{provider} SSE parse failure (stage=tool.name, category=empty)",
                        )
                      // Same null-tolerance as tool.id: continuation chunks
                      // from some servers carry explicit "name": null.
                      Some(Null) | None => None
                      Some(_) =>
                        raise @posoco.ModelError::ResponseParse(
                          "\{provider} SSE parse failure (stage=tool.name, category=wrong_type)",
                        )
                    }
                    let a : String? = match f.get("arguments") {
                      Some(String(s)) => Some(s)
                      // Explicit "arguments": null carries no delta bytes.
                      Some(Null) | None => None
                      Some(_) =>
                        raise @posoco.ModelError::ResponseParse(
                          "\{provider} SSE parse failure (stage=tool.arguments, category=wrong_type)",
                        )
                    }
                    if n is None && a is None {
                      raise @posoco.ModelError::ResponseParse(
                        "\{provider} SSE parse failure (stage=tool.function, category=empty)",
                      )
                    }
                    (n, a)
                  }
                  Some(_) =>
                    raise @posoco.ModelError::ResponseParse(
                      "\{provider} SSE parse failure (stage=tool.function, category=wrong_type)",
                    )
                  None =>
                    raise @posoco.ModelError::ResponseParse(
                      "\{provider} SSE parse failure (stage=tool.function, category=missing)",
                    )
                }
                let chunk = @posoco.StreamChunk::ToolCallDelta(
                  index=idx,
                  id~,
                  name~,
                  arguments_delta=args_delta,
                )
                on_chunk(chunk)
                acc.push(chunk)
              }
              _ =>
                raise @posoco.ModelError::ResponseParse(
                  "\{provider} SSE parse failure (stage=tool, category=not_object)",
                )
            }
          }
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=delta.tool_calls, category=wrong_type)",
          )
        None => ()
      }
    }
    // A choice with neither delta nor finish_reason carries no content;
    // tolerate both a missing key and an explicit null.
    Some(Null) | None => ()
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=delta, category=wrong_type)",
      )
  }
  false
}

///|
/// Extract the cached input-token count from one chat-completions `usage`
/// object. NO openai-compatible endpoint is obliged to report caching at
/// all — OpenAI itself only populates the field for prompts at or above
/// the ~1024-token caching threshold — so absence is a normal outcome,
/// mapped to None, never a parse failure. The spellings, each tied to a
/// documented source:
/// - OpenAI (and vLLM following its usage schema):
///   `prompt_tokens_details.cached_tokens`
///   (developers.openai.com/api/docs/guides/prompt-caching)
/// - DeepSeek: `prompt_cache_hit_tokens` (hit + miss = prompt_tokens)
///   (api-docs.deepseek.com/guides/kv_cache)
/// - Moonshot: usage-top-level `cached_tokens` — the spelling this repo's
///   kimi extension has always parsed (platform.kimi.ai context caching)
/// - Anthropic-origin field surfaced by OpenAI-compatible gateways
///   (Portkey, LiteLLM, TrueFoundry, Zenlayer, LangWatch):
///   `cache_read_input_tokens`
/// An endpoint reporting some yet-unknown spelling also reads None — the
/// consumer degrades to "no cache facts", never a fabricated rate.
pub fn uncached_input_tokens_from_usage(usage : Map[String, Json]) -> Int? {
  match usage.get("prompt_cache_miss_tokens") {
    Some(Json::Number(n, ..)) => Some(n.to_int())
    _ => None
  }
}

///|
pub fn cached_input_tokens_from_usage(usage : Map[String, Json]) -> Int? {
  let spelling = match usage.get("prompt_tokens_details") {
    Some(Json::Object(details)) => details.get("cached_tokens")
    _ => None
  }
  let spelling = match spelling {
    Some(_) => spelling
    None => usage.get("prompt_cache_hit_tokens")
  }
  let spelling = match spelling {
    Some(_) => spelling
    None => usage.get("cached_tokens")
  }
  let spelling = match spelling {
    Some(_) => spelling
    None => usage.get("cache_read_input_tokens")
  }
  match spelling {
    Some(Json::Number(n, ..)) => Some(n.to_int())
    _ => None
  }
}

///|
/// Extract Usage from a chunk's `usage` object. `prompt_tokens` /
/// `completion_tokens` / `total_tokens` are accepted. With
/// `usage_fields_required~` every field must be present (loud on missing);
/// otherwise missing fields map to None.
fn extract_stream_usage(
  provider : String,
  root : Map[String, Json],
  usage_fields_required~ : Bool,
) -> @posoco.Usage raise @posoco.ModelError {
  match root.get("usage") {
    Some(Object(u)) => {
      let prompt = match u.get("prompt_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=usage.prompt_tokens, category=wrong_type)",
          )
        None =>
          if usage_fields_required {
            raise @posoco.ModelError::ResponseParse(
              "\{provider} SSE parse failure (stage=usage.prompt_tokens, category=missing)",
            )
          } else {
            None
          }
      }
      let completion = match u.get("completion_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=usage.completion_tokens, category=wrong_type)",
          )
        None =>
          if usage_fields_required {
            raise @posoco.ModelError::ResponseParse(
              "\{provider} SSE parse failure (stage=usage.completion_tokens, category=missing)",
            )
          } else {
            None
          }
      }
      let total = match u.get("total_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=usage.total_tokens, category=wrong_type)",
          )
        None =>
          if usage_fields_required {
            raise @posoco.ModelError::ResponseParse(
              "\{provider} SSE parse failure (stage=usage.total_tokens, category=missing)",
            )
          } else {
            None
          }
      }
      {
        input_tokens: prompt,
        output_tokens: completion,
        total_tokens: total,
        cached_input_tokens: cached_input_tokens_from_usage(u),
        uncached_input_tokens: uncached_input_tokens_from_usage(u),
      }
    }
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=usage, category=wrong_type)",
      )
    None =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=usage, category=missing)",
      )
  }
}

///|
/// Bounded, enum-like error metadata from a provider error object. Only
/// `type` and `code` may cross into the failure message, and only when they
/// are short charset-bounded labels (so no prompt/request text can ride
/// along). Returns "" or e.g. ", error_type=CreditsError, error_code=402".
fn extract_error_labels(err : Map[String, Json]) -> String {
  let buf = StringBuilder()
  match err.get("type") {
    Some(String(t)) =>
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
    Some(String(c)) =>
      match sanitize_error_label(c) {
        Some(label) => {
          buf.write_string(", error_code=")
          buf.write_string(label)
        }
        None => ()
      }
    Some(Number(n, ..)) => {
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
