///|
/// replay.mbt — lossless reasoning replay for the Messages dialect.
///
/// Assistant turns produced with extended thinking carry protocol state the
/// canonical fields cannot represent: thinking signatures, redacted thinking
/// payloads, and the original block ordering required for the next request.
/// The kit stores that state inside `Reasoning.raw` under an explicit,
/// self-describing envelope:
///
///     {"codec": "posoco.kit.messages", "version": 1,
///      "fingerprint": "<fnv1a64-hex>", "blocks": [ ...wire blocks... ]}
///
/// Invariants:
/// - Blocks are stored verbatim (signatures and redacted payloads are never
///   stripped, decrypted, or rendered as text) in original relative order.
/// - The fingerprint pins the envelope to the canonical assistant turn it
///   was captured from (visible text + tool calls). Replay recomputes the
///   fingerprint from the CURRENT transcript message and raises a typed
///   error on mismatch, so a edited/truncated turn can never replay stale
///   provider state.
/// - Foreign or malformed envelopes are typed errors, never ignored —
///   silently dropping the state would claim losslessness falsely.
/// - The envelope is only produced and consumed by this codec; replaying it
///   through another protocol's codec is a caller error the fingerprint tag
///   makes detectable.

///|
/// Envelope codec tag stored in `Reasoning.raw`.
const CODEC_TAG = "posoco.kit.messages"

///|
/// Current envelope version.
const CODEC_VERSION = 1

///|
/// FNV-1a 64-bit over the canonical description of an assistant turn's
/// visible payload: every text/image content block and every tool call
/// (id, name, arguments JSON). Deterministic across processes for equal
/// transcript values.
fn assistant_fingerprint(
  content~ : Array[@posoco.Content],
  tool_calls~ : Array[@posoco.ToolCall],
) -> String {
  let mut hash : UInt64 = 0xcbf29ce484222325UL
  fn feed(text : String) -> Unit {
    for ch in text {
      hash = hash * 0x100000001b3UL
      hash = hash ^ ch.to_int().to_uint64()
    }
    hash = hash * 0x100000001b3UL
    hash = hash ^ 0x1fUL
  }
  for block in content {
    match block {
      @posoco.Content::Text(text) => {
        feed("T|")
        feed(text)
      }
      @posoco.Content::Image(media_type~, data~) => {
        feed("I|")
        feed(media_type)
        feed("|")
        feed(data)
      }
    }
  }
  for tc in tool_calls {
    feed("C|")
    feed(tc.call_id.to_string())
    feed("|")
    feed(tc.name.to_string())
    feed("|")
    feed(tc.arguments.stringify())
  }
  fn hex_digit(n : UInt64) -> Char {
    let digit = (n & 0xfUL).to_int()
    if digit < 10 {
      Char::from_int(48 + digit)
    } else {
      Char::from_int(87 + digit)
    }
  }
  let builder = StringBuilder()
  for shift = 60; shift >= 0; shift = shift - 4 {
    builder.write_char(hex_digit(hash >> shift))
  }
  builder.to_string()
}

///|
/// Validate one wire thinking-family block for envelope capture. Returns the
/// block unchanged when well-formed; typed errors for shapes that would
/// silently lose replay state (empty thinking with no signature, empty
/// redacted payload, non-object blocks without a type tag).
fn validated_replay_block(
  provider~ : String,
  block : Json,
) -> Json raise @posoco.ModelError {
  let fields = match block {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} response parse failure (stage=replay.block, category=not_object)",
      )
  }
  let kind = match fields.get("type") {
    Some(Json::String(kind)) if kind != "" => kind
    Some(Json::String(_)) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} response parse failure (stage=replay.block_type, category=empty)",
      )
    Some(_) | None =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} response parse failure (stage=replay.block_type, category=missing)",
      )
  }
  match kind {
    "thinking" => {
      let has_text = match fields.get("thinking") {
        Some(Json::String(text)) => text != ""
        Some(Json::Null) | None => false
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} response parse failure (stage=replay.thinking, category=wrong_type)",
          )
      }
      let has_signature = match fields.get("signature") {
        Some(Json::String(sig)) => sig != ""
        Some(Json::Null) | None => false
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} response parse failure (stage=replay.signature, category=wrong_type)",
          )
      }
      if !has_text && !has_signature {
        raise @posoco.ModelError::ResponseParse(
          "\{provider} response parse failure (stage=replay.thinking, category=empty)",
        )
      }
      block
    }
    "redacted_thinking" =>
      match fields.get("data") {
        Some(Json::String(data)) =>
          if data != "" {
            block
          } else {
            raise @posoco.ModelError::ResponseParse(
              "\{provider} response parse failure (stage=replay.redacted, category=empty)",
            )
          }
        Some(Json::Null) | None =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} response parse failure (stage=replay.redacted, category=missing)",
          )
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "\{provider} response parse failure (stage=replay.redacted, category=wrong_type)",
          )
      }
    // Opaque extension block: preserved for transcript continuity, never
    // interpreted. Anything object-shaped with a type tag passes through.
    _ => block
  }
}

///|
/// Build the replay envelope for one assistant turn. `blocks` are the
/// thinking-family / opaque wire blocks in original response order.
pub fn build_replay_envelope(
  content~ : Array[@posoco.Content],
  tool_calls~ : Array[@posoco.ToolCall],
  blocks~ : Array[Json],
  full_blocks~ : Array[Json]? = None,
) -> Json {
  let fields : Array[(String, Json)] = [
    ("codec", Json::string(CODEC_TAG)),
    ("version", Json::number(CODEC_VERSION.to_double())),
    ("fingerprint", Json::string(assistant_fingerprint(content~, tool_calls~))),
    ("blocks", Json::array(blocks.copy())),
  ]
  match full_blocks {
    Some(all) => fields.push(("full_blocks", Json::array(all.copy())))
    None => ()
  }
  Json::object(Map::from_array(fields))
}

///|
/// Parse and fully validate a `Reasoning.raw` payload for replay. Returns
/// the stored wire blocks. Typed errors cover: foreign codecs, unknown
/// versions, missing/malformed fingerprints, missing blocks, and stale
/// state (fingerprint does not match the current canonical turn).
pub fn parse_replay_envelope(
  provider~ : String,
  raw : Json,
  content~ : Array[@posoco.Content],
  tool_calls~ : Array[@posoco.ToolCall],
) -> Array[Json] raise @posoco.ModelError {
  let fields = match raw {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} replay validation failure (stage=envelope, category=not_object)",
      )
  }
  match fields.get("codec") {
    Some(Json::String(tag)) =>
      if tag != CODEC_TAG {
        raise @posoco.ModelError::ResponseParse(
          "\{provider} replay validation failure (stage=codec, category=foreign)",
        )
      }
    Some(_) | None =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} replay validation failure (stage=codec, category=missing)",
      )
  }
  match fields.get("version") {
    Some(Json::Number(n, ..)) =>
      if n != CODEC_VERSION.to_double() {
        raise @posoco.ModelError::ResponseParse(
          "\{provider} replay validation failure (stage=version, category=unsupported)",
        )
      }
    Some(_) | None =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} replay validation failure (stage=version, category=missing)",
      )
  }
  let stored = match fields.get("fingerprint") {
    Some(Json::String(fp)) if fp != "" => fp
    Some(Json::String(_)) | Some(_) | None =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} replay validation failure (stage=fingerprint, category=missing)",
      )
  }
  let blocks = match fields.get("blocks") {
    Some(Json::Array(blocks)) => blocks
    Some(_) | None =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} replay validation failure (stage=blocks, category=missing)",
      )
  }
  let current = assistant_fingerprint(content~, tool_calls~)
  if current != stored {
    raise @posoco.ModelError::ResponseParse(
      "\{provider} replay validation failure (stage=fingerprint, category=stale)",
    )
  }
  for block in blocks {
    ignore(validated_replay_block(provider~, block))
  }
  // New captures preserve ALL assistant blocks in wire order. The original
  // canonical visible content, tool calls and opaque blocks must match the
  // stored sequence before it can be emitted verbatim again.
  match fields.get("full_blocks") {
    Some(Json::Array(all)) => {
      let visible : Array[@posoco.Content] = []
      let calls : Array[@posoco.ToolCall] = []
      let replay : Array[Json] = []
      for block in all {
        match decode_content_block(provider~, block) {
          DecodedBlock::Text(text) =>
            if text != "" {
              visible.push(@posoco.Content::Text(text))
            }
          DecodedBlock::ToolCall(call) => calls.push(call)
          DecodedBlock::Replay(raw_block) => replay.push(raw_block)
        }
      }
      let canonical_text = StringBuilder()
      let replay_text = StringBuilder()
      for item in content {
        match item {
          @posoco.Content::Text(value) => canonical_text.write_string(value)
          @posoco.Content::Image(..) =>
            raise @posoco.ModelError::ResponseParse(
              "\{provider} replay validation failure (stage=full_blocks, category=unsupported_image)",
            )
        }
      }
      for item in visible {
        match item {
          @posoco.Content::Text(value) => replay_text.write_string(value)
          @posoco.Content::Image(..) => ()
        }
      }
      if replay_text.to_string() != canonical_text.to_string() ||
        calls != tool_calls || replay != blocks {
        raise @posoco.ModelError::ResponseParse(
          "\{provider} replay validation failure (stage=full_blocks, category=stale)",
        )
      }
      all
    }
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} replay validation failure (stage=full_blocks, category=wrong_type)",
      )
    None => blocks
  }
}

///|
/// Whether this envelope contains a complete original wire block sequence.
/// Old envelopes contain only opaque replay blocks and use the historical
/// thinking-first reconstruction for backwards compatibility.
pub fn is_complete_messages_replay_envelope(raw : Json) -> Bool {
  match raw {
    Json::Object(fields) =>
      fields.get("codec") == Some(Json::string(CODEC_TAG)) &&
      fields.get("full_blocks") is Some(Json::Array(_))
    _ => false
  }
}

///|
/// True when `raw` carries this kit's replay envelope. Foreign payloads
/// (another codec's replay state) return false so callers can route them;
/// malformed same-codec envelopes still fail loudly at replay time.
pub fn is_messages_replay_envelope(raw : Json?) -> Bool {
  match raw {
    Some(Json::Object(fields)) =>
      fields.get("codec") == Some(Json::string(CODEC_TAG))
    _ => false
  }
}
