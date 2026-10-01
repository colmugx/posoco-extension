///|
/// OpenAI-private raw compact-window replay.
///
/// The standalone `/responses/compact` output array is the authoritative next
/// input window ("pass it into your next /responses call as-is — do not
/// prune"), and canonical messages cannot represent every item faithfully
/// (opaque `encrypted_content`, item `id`/`status`, multi-modal parts,
/// hosted-tool items). The compact decode therefore stores the original
/// output array verbatim in a versioned provider-private envelope on a
/// dedicated synthetic assistant anchor, and keeps the decoded messages after
/// the anchor as the canonical projection for user/activation/context
/// consumers. The shared input encoder below recognizes the envelope,
/// validates that the projection still equals a deterministic decode of the
/// stored output, and then replays the raw items exactly once, skipping only
/// the validated projection.

///|
/// Marker key of the provider-private envelope. Never serialized as a wire
/// item; the encoder strips it by replaying the stored output instead.
fn compact_raw_envelope_key() -> String {
  "posoco.openai.compact_raw_window"
}

///|
fn json_deep_copy(value : Json) -> Json {
  match value {
    Json::Array(items) => Json::array(items.map(json_deep_copy))
    Json::Object(fields) => {
      let copied : Array[(String, Json)] = []
      for key, v in fields {
        copied.push((key, json_deep_copy(v)))
      }
      Json::object(Map::from_array(copied))
    }
    other => other
  }
}

///|
/// Anchor reasoning payload: the versioned envelope holding the compact
/// output array verbatim. The array is deep-copied so the envelope never
/// aliases the response tree (or the projection's own raw arrays) the caller
/// may still hold.
fn compact_raw_anchor_reasoning(output : Array[Json]) -> @posoco.Reasoning {
  let payload = Json::object(
    Map::from_array([
      ("version", Json::number(1)),
      ("output", Json::array(output.map(json_deep_copy))),
    ]),
  )
  @posoco.Reasoning::{
    content: "",
    raw: Some(
      Json::object(Map::from_array([(compact_raw_envelope_key(), payload)])),
    ),
  }
}

///|
/// Recognize the synthetic anchor: an assistant message whose `Reasoning.raw`
/// is exactly the versioned compact raw envelope. Returns the stored output
/// items, or `None` for ordinary messages — including messages carrying the
/// legacy bare reasoning-item arrays. A corrupted anchor (visible content or
/// tool calls attached to the envelope, unknown version, missing/invalid
/// output) fails loudly instead of silently degrading to lossy projection
/// replay.
fn compact_anchor_output(
  msg : @posoco.Message,
) -> Array[Json]? raise @posoco.ModelError {
  match msg {
    @posoco.Message::AssistantMessage(content~, tool_calls~, reasoning~, ..) =>
      match reasoning {
        Some({ raw: Some(Json::Object(fields)), .. }) =>
          match fields.get(compact_raw_envelope_key()) {
            Some(value) => {
              if content.length() != 0 || !tool_calls.is_empty() {
                raise @posoco.ModelError::ResponseParse(
                  "OpenAI compact replay failure (stage=anchor, category=corrupted)",
                )
              }
              let payload = match value {
                Json::Object(payload) => payload
                _ =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI compact replay failure (stage=anchor, category=wrong_type)",
                  )
              }
              match payload.get("version") {
                Some(Json::Number(v, ..)) if v == 1.0 => ()
                _ =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI compact replay failure (stage=anchor, category=version)",
                  )
              }
              match payload.get("output") {
                Some(Json::Array(items)) => Some(items)
                Some(Json::Null) | None =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI compact replay failure (stage=anchor, category=missing_output)",
                  )
                Some(_) =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI compact replay failure (stage=anchor, category=wrong_type)",
                  )
              }
            }
            _ => None
          }
        _ => None
      }
    _ => None
  }
}

///|
/// Deterministic canonical projection of the stored compact output: the same
/// decode used at compact time, recomputed so the encoder can prove the
/// window's projection was neither mutated nor truncated before the raw items
/// replay.
fn compact_projection_of(
  output : Array[Json],
) -> Array[@posoco.Message] raise @posoco.ModelError {
  openai_items_to_posoco_messages(Json::array(output)) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI compact replay failure (stage=projection, category=invalid_output)",
      )
  }
}

///|
/// The single OpenAI input encoder, shared by chat and recompact request
/// bodies. Messages before an anchor (e.g. legitimate host-prefixed system or
/// context injection) and messages appended after the validated projection
/// encode normally; the anchor's stored output items replay verbatim exactly
/// once. A projection that no longer matches its stored output is an explicit
/// failure — never a silent stale replay or a lossy fallback.
fn openai_encode_window_items(
  messages : Array[@posoco.Message],
) -> Array[Json] raise @posoco.ModelError {
  // Tool-result attachments degrade to explicit placeholders until per-model
  // image_input metadata lands in this provider (openai-compat has the
  // config; the first-party catalog does not yet). The fold is
  // length-preserving, so anchor/projection indices below are stable.
  let folded = @responses.fold_tool_attachments(messages, false)
  let mut anchor_at = -1
  let mut anchor_output : Array[Json] = []
  for i, m in folded {
    match compact_anchor_output(m) {
      Some(output) => {
        if anchor_at >= 0 {
          raise @posoco.ModelError::ResponseParse(
            "OpenAI compact replay failure (stage=anchor, category=duplicate)",
          )
        }
        anchor_at = i
        anchor_output = output
      }
      None => ()
    }
  }
  let items : Array[Json] = []
  if anchor_at < 0 {
    for m in folded {
      for item in @responses.message_to_responses_items(m) {
        items.push(item)
      }
    }
    return items
  }
  if anchor_output.is_empty() {
    // A compact output of [] never becomes an anchor; an empty stored output
    // can only come from a corrupted envelope and must not replay as success.
    raise @posoco.ModelError::ResponseParse(
      "OpenAI compact replay failure (stage=anchor, category=empty_output)",
    )
  }
  let projection = compact_projection_of(anchor_output)
  let projection_end = anchor_at + 1 + projection.length()
  if folded.length() < projection_end {
    raise @posoco.ModelError::ResponseParse(
      "OpenAI compact replay failure (stage=projection, category=incomplete)",
    )
  }
  for i in 1..<=projection.length() {
    if folded[anchor_at + i] != projection[i - 1] {
      raise @posoco.ModelError::ResponseParse(
        "OpenAI compact replay failure (stage=projection, category=mismatch)",
      )
    }
  }
  for i in 0..<anchor_at {
    for item in @responses.message_to_responses_items(folded[i]) {
      items.push(item)
    }
  }
  for item in anchor_output {
    items.push(json_deep_copy(item))
  }
  for i in projection_end..<folded.length() {
    for item in @responses.message_to_responses_items(folded[i]) {
      items.push(item)
    }
  }
  items
}
