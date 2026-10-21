///|
/// SSE streaming for standard OpenAI Chat Completions.
///
/// The parser is shared across chat-completions providers in
/// posoco-kit-chat-completions; this wrapper pins the "opencode-zen"
/// prefix used in every raised message. See the kit for the tolerance policy.
/// Before delegating, the OpenCode gateway reasoning dialect is normalized
/// onto the standard shape (see `normalize_zen_reasoning_dialect`).

///|
/// Normalize the OpenCode gateway reasoning dialect onto the standard Chat
/// Completions shape. The Go gateway streams reasoning as `delta.reasoning`,
/// while the shared kit (and the DeepSeek/GLM/Kimi upstreams that demand
/// reasoning_content replay) only know the standard `reasoning_content`
/// spelling. When a delta carries `reasoning` without `reasoning_content`,
/// the text is copied under the standard field. Anything unparseable or
/// already standard passes through untouched — the kit keeps raising its own
/// labeled parse failure, and standard upstreams pay no rewrite cost.
fn normalize_zen_reasoning_dialect(data : String) -> String {
  if !data.contains("reasoning") {
    return data
  }
  let event : Json = @json.parse(data) catch { _ => return data }
  guard event is Object(root) else { return data }
  let choices = match root.get("choices") {
    Some(Array(choices)) => choices
    _ => return data
  }
  let mut changed = false
  for choice in choices {
    let delta = match choice {
      Object(choice_obj) =>
        match choice_obj.get("delta") {
          Some(Object(delta)) => delta
          _ => continue
        }
      _ => continue
    }
    match (delta.get("reasoning_content"), delta.get("reasoning")) {
      (None, Some(String(text))) => {
        delta["reasoning_content"] = Json::string(text)
        changed = true
      }
      _ => ()
    }
  }
  if changed {
    event.stringify()
  } else {
    data
  }
}

///|
/// Parse one SSE data line into StreamChunk(s) and feed to accumulator.
/// Returns true when the stream is finished ([DONE] or finish_reason present).
fn process_zen_sse(
  data : String,
  acc : @posoco.StreamAccumulator,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> Bool raise @posoco.ModelError {
  @chatkit.process_chat_completions_sse(
    provider="opencode-zen",
    normalize_zen_reasoning_dialect(data),
    acc,
    on_chunk,
  )
}
