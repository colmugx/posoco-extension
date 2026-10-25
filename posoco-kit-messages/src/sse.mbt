///|
/// sse.mbt — stateful SSE decoding for the Messages dialect.
///
/// Two layers, both pure and deterministic:
///
/// 1. `SseDecoder` frames raw transport text into `SseEvent`s (event name +
///    data payload), tolerating chunk boundaries anywhere — including mid
///    line and mid multi-line data.
/// 2. `process_messages_event` folds one event into the canonical
///    accumulator and this kit's replay state. The Messages vocabulary is
///    its own: terminal is `message_stop` (never a `[DONE]` marker), `ping`
///    is explicitly not completion, and `error` events are protocol
///    failures, not output.

///|
/// One framed SSE event. `name` is the `event:` field when the transport
/// surfaced it; Messages events also repeat the type inside the JSON
/// payload, and the payload wins when both exist.
pub(all) struct SseEvent {
  name : String?
  data : String
} derive(Eq, Debug)

///|
pub extend SseEvent with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend SseEvent with Eq::{not_equal, equal}

///|
/// Incremental SSE framer. Feed arbitrary transport text; completed events
/// come back as a batch. Line endings are normalized (\r\n and \n); comment
/// lines (leading `:`) and unknown fields (`retry`, `id`) are ignored per
/// the SSE rules; multi-line `data:` fields join with \n. A blank line
/// dispatches the event; an incomplete trailing event is held for the next
/// push and discarded at `flush` per the SSE spec (a truncated stream is
/// then caught by the terminal check, never by guessed content).
pub struct SseDecoder {
  priv buf : StringBuilder
  priv mut data_lines : Array[String]
  priv mut event_name : String?
} derive(Debug)

///|
pub extend SseDecoder with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn SseDecoder::SseDecoder() -> SseDecoder {
  { buf: StringBuilder(), data_lines: [], event_name: None, }
}

///|
fn SseDecoder::reset_event(self : SseDecoder) -> Unit {
  self.data_lines = []
  self.event_name = None
}

///|
fn SseDecoder::complete_event(self : SseDecoder) -> SseEvent? {
  if self.data_lines.is_empty() {
    // Blank dispatch after comments-only or empty event: not an event.
    self.reset_event()
    return None
  }
  let joined = StringBuilder()
  for i, line in self.data_lines {
    if i > 0 {
      joined.write_string("\n")
    }
    joined.write_string(line)
  }
  let event : SseEvent = { name: self.event_name, data: joined.to_string(), }
  self.reset_event()
  Some(event)
}

///|
/// Feed one arbitrary transport fragment; returns every event completed by
/// it. Never raises: malformed field lines are ignored per the SSE spec.
pub fn SseDecoder::push(self : SseDecoder, text : String) -> Array[SseEvent] {
  let events : Array[SseEvent] = []
  self.buf.write_string(text)
  let pending = self.buf.to_string()
  self.buf.reset()
  let len = pending.length()
  let mut start = 0
  let mut i = 0
  while i < len {
    if pending[i] == '\n' {
      let mut end = i
      if end > start && pending[end - 1] == '\r' {
        end -= 1
      }
      let line = pending[start:end].to_owned()
      start = i + 1
      if line == "" {
        match self.complete_event() {
          Some(event) => events.push(event)
          None => ()
        }
      } else if line.has_prefix(":") {
        // Comment: ignored.
      } else {
        let (field, value) = match line.find(":") {
          Some(index) => {
            let mut value = line[index + 1:].to_owned()
            // One optional leading space after the colon is stripped.
            if value.has_prefix(" ") {
              value = value[1:].to_owned()
            }
            (line[:index].to_owned(), value)
          }
          None => (line, "")
        }
        match field {
          "data" => self.data_lines.push(value)
          "event" => self.event_name = Some(value)
          // `id` / `retry` and anything else: irrelevant to this codec.
          _ => ()
        }
      }
    }
    i += 1
  }
  if start < len {
    self.buf.write_string(pending[start:].to_owned())
  }
  events
}

///|
/// Flush at stream end. Per the SSE spec an unterminated trailing event is
/// discarded; the terminal check (`classify_stream_termination`) is what
/// surfaces a truncated stream as an error.
pub fn SseDecoder::flush(self : SseDecoder) -> Unit {
  self.reset_event()
  self.buf.reset()
}

///|
/// Internal per-content-block builder, correlated by wire index.
priv struct BlockAccum {
  kind : String
  text : StringBuilder
  signature : StringBuilder
  mut tool_id : String
  mut tool_name : String
  arguments : StringBuilder
  mut stopped : Bool
} derive(Debug)

///|
fn BlockAccum::BlockAccum(kind~ : String) -> BlockAccum {
  {
    kind,
    text: StringBuilder(),
    signature: StringBuilder(),
    tool_id: "",
    tool_name: "",
    arguments: StringBuilder(),
    stopped: false,
  }
}

///|
/// Cumulative usage snapshot. Message-shaped snapshots are partial by
/// design: `message_start` reports the input side, `message_delta` reports
/// the (growing) output side. Per dimension the LATEST report wins —
/// snapshots are never summed, so the final reading is exactly one value
/// per dimension.
priv struct UsageSnapshot {
  input_tokens : Int32?
  output_tokens : Int32?
  cache_creation : Int32?
  cache_read : Int32?
} derive(Debug)

///|
/// Mutable per-stream state: one instance per streamed response. Never
/// share across concurrent streams — isolation is by construction (no
/// global state anywhere in the kit; each decoder owns its maps).
pub(all) struct MessagesSseState {
  priv mut started : Bool
  priv mut stopped : Bool
  priv blocks : Map[Int32, BlockAccum]
  /// wire content-block index -> compact accumulator tool-call slot
  /// (canonical tool-call indices are contiguous 0-based over tool calls
  /// only; wire indices interleave with text/thinking blocks).
  priv tool_slots : Map[Int32, Int32]
  priv replay_blocks : Array[Json]
  priv full_blocks : Map[Int32, Json]
  priv mut next_block_index : Int32
  priv mut response_id : String
  priv mut model : String
  priv mut usage : UsageSnapshot?
  priv mut cache_creation_split : MessagesCacheCreation?
  priv mut stop_reason : String
  priv mut stop_sequence : String?
} derive(Debug)

///|
pub extend MessagesSseState with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn MessagesSseState::MessagesSseState() -> MessagesSseState {
  {
    started: false,
    stopped: false,
    blocks: Map::from_array([]),
    tool_slots: Map::from_array([]),
    replay_blocks: [],
    full_blocks: Map::from_array([]),
    next_block_index: 0,
    response_id: "",
    model: "",
    usage: None,
    cache_creation_split: None,
    stop_reason: "",
    stop_sequence: None,
  }
}

///|
fn MessagesSseState::tool_slot(self : MessagesSseState, wire : Int32) -> Int32 {
  match self.tool_slots.get(wire) {
    Some(slot) => slot
    None => {
      let slot = self.tool_slots.length()
      self.tool_slots[wire] = slot
      slot
    }
  }
}

///|
/// Bounded provider-error detail: only enum-like labels cross into the
/// message; free-text fields never do.
fn extract_error_labels(err : Map[String, Json]) -> String {
  let mut labels = ""
  for entry in err {
    let (key, value) = entry
    if key == "type" || key == "code" {
      match value {
        Json::String(s) =>
          if s.length() <= 120 {
            labels += " \{key}=\{s}"
          } else {
            labels += " \{key}=<long>"
          }
        _ => ()
      }
    }
  }
  labels
}

///|
/// One usage counter field from a snapshot object: non-negative integer,
/// or absent/null (meaning "not restated in this snapshot").
fn snapshot_counter(
  provider~ : String,
  fields : Map[String, Json],
  key~ : String,
) -> Int32? raise @posoco.ModelError {
  match fields.get(key) {
    Some(Json::Number(n, ..)) =>
      if n >= 0.0 && n <= 2147483647.0 && n == n.floor() {
        Some(n.to_int())
      } else {
        raise @posoco.ModelError::ResponseParse(
          "\{provider} usage parse failure (stage=\{key}, category=out_of_range)",
        )
      }
    Some(Json::Null) | None => None
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} usage parse failure (stage=\{key}, category=wrong_type)",
      )
  }
}

///|
/// Merge one (partial) cumulative usage snapshot: per dimension the latest
/// report wins; dimensions absent from this snapshot keep their earlier
/// value. A snapshot object with no counters is tolerated (no-op).
fn MessagesSseState::merge_usage(
  self : MessagesSseState,
  provider~ : String,
  usage : Json,
) -> Unit raise @posoco.ModelError {
  let fields = match usage {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} usage parse failure (stage=usage, category=not_object)",
      )
  }
  match fields.get("cache_creation") {
    Some(Json::Object(_)) => {
      let part = parse_messages_cache_creation(usage)
      let prior = self.cache_creation_split
      self.cache_creation_split = Some({
        ephemeral_5m_input_tokens: match part.ephemeral_5m_input_tokens {
          Some(n) => Some(n)
          None =>
            match prior {
              Some(prev) => prev.ephemeral_5m_input_tokens
              None => None
            }
        },
        ephemeral_1h_input_tokens: match part.ephemeral_1h_input_tokens {
          Some(n) => Some(n)
          None =>
            match prior {
              Some(prev) => prev.ephemeral_1h_input_tokens
              None => None
            }
        },
      })
    }
    Some(Json::Null) | None => ()
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} usage parse failure (stage=cache_creation, category=wrong_type)",
      )
  }
  let input = snapshot_counter(provider~, fields, key="input_tokens")
  let output = snapshot_counter(provider~, fields, key="output_tokens")
  let creation = snapshot_counter(
    provider~,
    fields,
    key="cache_creation_input_tokens",
  )
  let read = snapshot_counter(provider~, fields, key="cache_read_input_tokens")
  if input is None && output is None && creation is None && read is None {
    return
  }
  let previous = self.usage
  self.usage = Some({
    input_tokens: match input {
      Some(n) => Some(n)
      None =>
        match previous {
          Some(prev) => prev.input_tokens
          None => None
        }
    },
    output_tokens: match output {
      Some(n) => Some(n)
      None =>
        match previous {
          Some(prev) => prev.output_tokens
          None => None
        }
    },
    cache_creation: match creation {
      Some(n) => Some(n)
      None =>
        match previous {
          Some(prev) => prev.cache_creation
          None => None
        }
    },
    cache_read: match read {
      Some(n) => Some(n)
      None =>
        match previous {
          Some(prev) => prev.cache_read
          None => None
        }
    },
  })
}

///|
/// Native usage from the merged snapshot, only when the two protocol
/// counters are both known. Partial readings are withheld (`None`) rather
/// than zero-filled — the canonical completion keeps its canonical usage
/// only when the projection is mathematically complete.
fn MessagesSseState::native_usage(self : MessagesSseState) -> MessagesUsage? {
  match self.usage {
    Some(snapshot) =>
      match (snapshot.input_tokens, snapshot.output_tokens) {
        (Some(input), Some(output)) =>
          Some({
            input_tokens: input,
            output_tokens: output,
            cache_creation_input_tokens: snapshot.cache_creation,
            cache_read_input_tokens: snapshot.cache_read,
          })
        _ => None
      }
    None => None
  }
}

///|
/// Emit the final canonical Usage chunk exactly once, from the merged
/// cumulative snapshot. Withheld (partial) readings emit nothing — no
/// false usage ever reaches the accumulator.
fn MessagesSseState::emit_usage(
  self : MessagesSseState,
  acc : @posoco.StreamAccumulator,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> Unit raise @posoco.ModelError {
  match self.native_usage() {
    Some(native) => {
      let canonical = native.to_canonical()
      match
        (
          canonical.input_tokens,
          canonical.output_tokens,
          canonical.total_tokens,
        ) {
        (Some(input), Some(output), Some(total)) => {
          let chunk = @posoco.StreamChunk::Usage(
            input_tokens=input,
            output_tokens=output,
            total_tokens=total,
            cached_input_tokens=canonical.cached_input_tokens,
            uncached_input_tokens=canonical.uncached_input_tokens,
          )
          on_chunk(chunk)
          acc.push(chunk)
        }
        _ => ()
      }
    }
    None => ()
  }
}

///|
fn event_index(
  provider~ : String,
  fields : Map[String, Json],
) -> Int32 raise @posoco.ModelError {
  match fields.get("index") {
    Some(Json::Number(n, ..)) if n >= 0.0 && n <= 2147483647.0 && n == n.floor() =>
      n.to_int()
    Some(Json::Number(_)) | Some(_) | None =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=index, category=invalid)",
      )
  }
}

///|
/// Fold one framed SSE event into the stream. `event_name` is the SSE
/// `event:` field when the transport surfaces it; the JSON payload's `type`
/// wins when present (both carry the same vocabulary on the wire).
///
/// Returns `true` exactly when `message_stop` completed the stream.
/// Unknown event types are ignored (documented forward-compatibility
/// policy); malformed required fields inside KNOWN events are typed errors.
pub fn process_messages_event(
  provider~ : String,
  event_name~ : String? = None,
  data~ : String,
  acc~ : @posoco.StreamAccumulator,
  on_chunk~ : (@posoco.StreamChunk) -> Unit,
  state~ : MessagesSseState = MessagesSseState::MessagesSseState(),
) -> Bool raise @posoco.ModelError {
  let event : Json = @json.parse(data) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=json, payload_chars=\{data.length()})",
      )
  }
  let fields = match event {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=event, category=not_object)",
      )
  }
  // A bare {"error": ...} data line is a mid-stream provider failure, not
  // an event missing its type. Only bounded, enum-like labels cross into
  // the message; free-text fields never do.
  match fields.get("error") {
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
  let event_type = match fields.get("type") {
    Some(Json::String(t)) if t != "" => t
    Some(Json::String(_)) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=event_type, category=empty)",
      )
    Some(_) | None =>
      match event_name {
        Some(name) => name
        None =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=event_type, category=missing)",
          )
      }
  }
  if state.stopped {
    raise @posoco.ModelError::ResponseParse(
      "\{provider} SSE parse failure (stage=lifecycle, category=event_after_stop)",
    )
  }
  match event_type {
    "message_start" => {
      if state.started {
        raise @posoco.ModelError::ResponseParse(
          "\{provider} SSE parse failure (stage=lifecycle, category=duplicate_message_start)",
        )
      }
      let message = match fields.get("message") {
        Some(Json::Object(message)) => message
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=message, category=wrong_type)",
          )
        None =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=message, category=missing)",
          )
      }
      match message.get("role") {
        Some(Json::String("assistant")) => ()
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=role, category=unexpected)",
          )
      }
      match message.get("id") {
        Some(Json::String(id)) => state.response_id = id
        _ => ()
      }
      match message.get("model") {
        Some(Json::String(model)) => state.model = model
        _ => ()
      }
      state.started = true
      match message.get("usage") {
        Some(Json::Object(_)) =>
          state.merge_usage(
            provider~,
            message.get("usage").unwrap_or(Json::null()),
          )
        _ => ()
      }
      false
    }
    "content_block_start" => {
      let index = event_index(provider~, fields)
      if !state.started {
        raise @posoco.ModelError::ResponseParse(
          "\{provider} SSE parse failure (stage=lifecycle, category=block_before_start)",
        )
      }
      if index != state.next_block_index {
        raise @posoco.ModelError::ResponseParse(
          "\{provider} SSE parse failure (stage=index, category=non_sequential)",
        )
      }
      if state.blocks.contains(index) {
        raise @posoco.ModelError::ResponseParse(
          "\{provider} SSE parse failure (stage=lifecycle, category=duplicate_block)",
        )
      }
      let block = match fields.get("content_block") {
        Some(Json::Object(block)) => block
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=content_block, category=missing)",
          )
      }
      let kind = match block.get("type") {
        Some(Json::String(kind)) if kind != "" => kind
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=content_block.type, category=missing)",
          )
      }
      let accum = BlockAccum::BlockAccum(kind~)
      match kind {
        "tool_use" => {
          accum.tool_id = match block.get("id") {
            Some(Json::String(id)) if id != "" => id
            _ =>
              raise @posoco.ModelError::ResponseParse(
                "\{provider} SSE parse failure (stage=tool.id, category=invalid)",
              )
          }
          accum.tool_name = match block.get("name") {
            Some(Json::String(name)) if name != "" => name
            _ =>
              raise @posoco.ModelError::ResponseParse(
                "\{provider} SSE parse failure (stage=tool.name, category=invalid)",
              )
          }
          let slot = state.tool_slot(index)
          let chunk = @posoco.StreamChunk::ToolCallDelta(
            index=slot,
            id=Some(accum.tool_id),
            name=Some(accum.tool_name),
            arguments_delta=None,
          )
          on_chunk(chunk)
          acc.push(chunk)
        }
        "redacted_thinking" =>
          // Arrives complete; validated and captured verbatim into replay
          // state, never surfaced as text.
          match block.get("data") {
            Some(Json::String(data)) if data != "" => {
              let redacted = Json::object({
                "type": Json::string("redacted_thinking"),
                "data": Json::string(data),
              })
              state.replay_blocks.push(redacted)
              state.full_blocks[index] = redacted
            }
            _ =>
              raise @posoco.ModelError::ResponseParse(
                "\{provider} SSE parse failure (stage=replay.redacted, category=invalid)",
              )
          }
        // text / thinking: content arrives via deltas.
        _ => ()
      }
      state.blocks[index] = accum
      state.next_block_index += 1
      false
    }
    "content_block_delta" => {
      let index = event_index(provider~, fields)
      let accum = match state.blocks.get(index) {
        Some(accum) => accum
        None =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=lifecycle, category=delta_without_block)",
          )
      }
      if accum.stopped {
        raise @posoco.ModelError::ResponseParse(
          "\{provider} SSE parse failure (stage=lifecycle, category=delta_after_stop)",
        )
      }
      let delta = match fields.get("delta") {
        Some(Json::Object(delta)) => delta
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=delta, category=missing)",
          )
      }
      match delta.get("type") {
        Some(Json::String("text_delta")) => {
          if accum.kind != "text" {
            raise @posoco.ModelError::ResponseParse(
              "\{provider} SSE parse failure (stage=delta, category=block_type_mismatch)",
            )
          }
          match delta.get("text") {
            Some(Json::String(token)) => {
              accum.text.write_string(token)
              let chunk = @posoco.StreamChunk::TextDelta(token~)
              on_chunk(chunk)
              acc.push(chunk)
            }
            // Explicit null carries no content; a missing key or a wrong
            // type inside a known delta is malformed.
            Some(Json::Null) => ()
            _ =>
              raise @posoco.ModelError::ResponseParse(
                "\{provider} SSE parse failure (stage=text, category=missing)",
              )
          }
        }
        Some(Json::String("thinking_delta")) => {
          if accum.kind != "thinking" {
            raise @posoco.ModelError::ResponseParse(
              "\{provider} SSE parse failure (stage=delta, category=block_type_mismatch)",
            )
          }
          match delta.get("thinking") {
            Some(Json::String(token)) => {
              accum.text.write_string(token)
              let chunk = @posoco.StreamChunk::ReasoningDelta(token~)
              on_chunk(chunk)
              acc.push(chunk)
            }
            Some(Json::Null) => ()
            _ =>
              raise @posoco.ModelError::ResponseParse(
                "\{provider} SSE parse failure (stage=thinking, category=missing)",
              )
          }
        }
        Some(Json::String("signature_delta")) => {
          if accum.kind != "thinking" {
            raise @posoco.ModelError::ResponseParse(
              "\{provider} SSE parse failure (stage=delta, category=block_type_mismatch)",
            )
          }
          match delta.get("signature") {
            Some(Json::String(sig)) => accum.signature.write_string(sig)
            Some(Json::Null) => ()
            _ =>
              raise @posoco.ModelError::ResponseParse(
                "\{provider} SSE parse failure (stage=signature, category=missing)",
              )
          }
        }
        Some(Json::String("input_json_delta")) => {
          if accum.kind != "tool_use" {
            raise @posoco.ModelError::ResponseParse(
              "\{provider} SSE parse failure (stage=delta, category=block_type_mismatch)",
            )
          }
          match delta.get("partial_json") {
            Some(Json::String(fragment)) => {
              accum.arguments.write_string(fragment)
              let chunk = @posoco.StreamChunk::ToolCallDelta(
                index=state.tool_slot(index),
                id=None,
                name=None,
                arguments_delta=Some(fragment),
              )
              on_chunk(chunk)
              acc.push(chunk)
            }
            // Documented shape: partial_json may be explicitly null (e.g.
            // the closing delta of an arguments object that already
            // round-tripped complete).
            Some(Json::Null) => ()
            _ =>
              raise @posoco.ModelError::ResponseParse(
                "\{provider} SSE parse failure (stage=partial_json, category=missing)",
              )
          }
        }
        // A new delta type on a known block may carry meaningful content.
        // Do not silently drop it: that would corrupt the canonical output
        // or invalidate the opaque replay signature.
        Some(Json::String(_)) =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=delta.type, category=unsupported)",
          )
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=delta.type, category=missing)",
          )
      }
      false
    }
    "content_block_stop" => {
      let index = event_index(provider~, fields)
      let accum = match state.blocks.get(index) {
        Some(accum) => accum
        None =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=lifecycle, category=stop_without_block)",
          )
      }
      if accum.stopped {
        raise @posoco.ModelError::ResponseParse(
          "\{provider} SSE parse failure (stage=lifecycle, category=double_stop)",
        )
      }
      accum.stopped = true
      match accum.kind {
        "text" =>
          state.full_blocks[index] = Json::object({
            "type": Json::string("text"),
            "text": Json::string(accum.text.to_string()),
          })
        "thinking" => {
          let text = accum.text.to_string()
          let signature = accum.signature.to_string()
          if text == "" && signature == "" {
            raise @posoco.ModelError::ResponseParse(
              "\{provider} SSE parse failure (stage=replay.thinking, category=empty)",
            )
          }
          let fields_out : Array[(String, Json)] = [
            ("type", Json::string("thinking")),
            ("thinking", Json::string(text)),
          ]
          if signature != "" {
            fields_out.push(("signature", Json::string(signature)))
          }
          let full = Json::object(Map::from_array(fields_out))
          state.replay_blocks.push(full)
          state.full_blocks[index] = full
        }
        "tool_use" => {
          // Tool arguments are parsed only when the block completes: by
          // then the accumulated fragments must form a JSON object.
          let args_text = accum.arguments.to_string()
          let args_json = if args_text == "" {
            Json::object({})
          } else {
            @json.parse(args_text) catch {
              err => {
                let head = if args_text.length() <= 80 {
                  args_text
                } else {
                  args_text[:80].to_owned()
                }
                let tail = if args_text.length() <= 80 {
                  args_text
                } else {
                  args_text[args_text.length() - 80:].to_owned()
                }
                raise @posoco.ModelError::ResponseParse(
                  "\{provider} SSE parse failure (stage=tool.arguments, category=malformed, parse_error=\{err}, payload_chars=\{args_text.length()}, payload_head=\{head}, payload_tail=\{tail})",
                )
              }
            }
          }
          match args_json {
            Json::Object(_) =>
              state.full_blocks[index] = Json::object({
                "type": Json::string("tool_use"),
                "id": Json::string(accum.tool_id),
                "name": Json::string(accum.tool_name),
                "input": args_json,
              })
            _ =>
              raise @posoco.ModelError::ResponseParse(
                "\{provider} SSE parse failure (stage=tool.arguments, category=not_object)",
              )
          }
        }
        "redacted_thinking" => ()
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=block, category=unsupported)",
          )
      }
      false
    }
    "message_delta" => {
      match fields.get("delta") {
        Some(Json::Object(delta)) => {
          match delta.get("stop_reason") {
            Some(Json::String(reason)) => state.stop_reason = reason
            _ => ()
          }
          match delta.get("stop_sequence") {
            Some(Json::String(seq)) => state.stop_sequence = Some(seq)
            _ => ()
          }
        }
        _ => ()
      }
      match fields.get("usage") {
        Some(Json::Object(_)) =>
          state.merge_usage(
            provider~,
            fields.get("usage").unwrap_or(Json::null()),
          )
        _ => ()
      }
      false
    }
    "message_stop" => {
      if !state.started || state.stop_reason == "" {
        raise @posoco.ModelError::ResponseParse(
          "\{provider} SSE parse failure (stage=lifecycle, category=incomplete_message)",
        )
      }
      for _, block in state.blocks {
        if !block.stopped {
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=lifecycle, category=open_block)",
          )
        }
      }
      state.stopped = true
      // The canonical Finish chunk, mapped from the wire stop reason the
      // last message_delta reported (end_turn/stop_sequence -> "stop",
      // tool_use -> "tool_calls", max_tokens -> "length", unknown ->
      // preserved verbatim).
      if state.stop_reason != "" {
        let chunk = @posoco.StreamChunk::Finish(
          reason=acc_finish_string(reason=state.stop_reason),
        )
        on_chunk(chunk)
        acc.push(chunk)
      }
      // Exactly one canonical Usage chunk per stream, from the merged
      // cumulative snapshot — never one per message_delta.
      state.emit_usage(acc, on_chunk)
      true
    }
    // `ping` is keepalive, never completion.
    "ping" => false
    "error" =>
      raise @posoco.ModelError::Transport(
        "\{provider} SSE terminal failure (stage=error, category=provider_error)",
      )
    // Unknown event types: ignored for forward compatibility. They neither
    // complete the stream nor reset lifecycle state.
    _ => false
  }
}

///|
/// Accumulator-side finish string for a wire stop reason (same mapping as
/// `map_stop_reason`, expressed in the StreamChunk vocabulary that
/// `StreamAccumulator::to_completion` decodes).
fn acc_finish_string(reason~ : String) -> String {
  match reason {
    "end_turn" | "stop_sequence" => "stop"
    "tool_use" => "tool_calls"
    "max_tokens" => "length"
    other => other
  }
}

///|
/// Pure classification for stream termination, mirroring the other protocol
/// kits: EOF without a `message_stop` is a truncated stream — a typed
/// error, never inferred success from accumulated content.
pub(all) enum StreamTermination {
  ExplicitTerminal
  CleanEof
} derive(Eq, Debug)

///|
pub extend StreamTermination with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend StreamTermination with Eq::{not_equal, equal}

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
          "\{provider} SSE truncated (stage=eof, terminal=message_stop missing)",
        ),
      )
  }
}

///|
/// Assemble the final result after `message_stop`: the canonical completion
/// (accumulator-validated tool calls and usage) plus the protocol-local
/// facts and the fingerprint-pinned reasoning replay envelope. Calling
/// before the terminal event is a typed error; open content blocks are
/// malformed lifecycles.
pub fn messages_stream_result(
  provider~ : String,
  acc~ : @posoco.StreamAccumulator,
  state~ : MessagesSseState,
) -> MessagesResult raise @posoco.ModelError {
  if !state.stopped {
    raise @posoco.ModelError::ResponseParse(
      "\{provider} SSE parse failure (stage=lifecycle, category=missing_message_stop)",
    )
  }
  for _, block in state.blocks {
    if !block.stopped {
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=lifecycle, category=open_block)",
      )
    }
  }
  let completion = acc.to_completion() catch {
    @posoco.ModelError::ResponseParse(message) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} SSE parse failure (stage=tool_calls): " + message,
      )
    error => raise error
  }
  // Attach the replay envelope to the accumulated reasoning text. The
  // envelope's thinking blocks ARE the source of that text; the fingerprint
  // pins the envelope to this completion's own visible payload.
  let completion = if state.replay_blocks.is_empty() {
    completion
  } else {
    let message = completion.message
    let all_blocks : Array[Json] = []
    for i in 0..<state.next_block_index {
      match state.full_blocks.get(i) {
        Some(block) => all_blocks.push(block)
        None =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} SSE parse failure (stage=full_blocks, category=missing)",
          )
      }
    }
    let reasoning : @posoco.Reasoning? = Some({
      content: acc.reasoning(),
      raw: Some(
        build_replay_envelope(
          content=message.content,
          tool_calls=message.tool_calls,
          blocks=state.replay_blocks,
          full_blocks=Some(all_blocks),
        ),
      ),
    })
    { ..completion, message: { ..message, reasoning, }, }
  }
  {
    completion,
    stop_reason: state.stop_reason,
    stop_sequence: state.stop_sequence,
    response_id: state.response_id,
    model: state.model,
    usage: state.native_usage(),
    cache_creation: state.cache_creation_split,
    extensions: [],
  }
}
