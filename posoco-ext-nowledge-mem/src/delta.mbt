///|
/// Acknowledged sync cursor for one lane (upstream AcknowledgedCursor): the
/// prefix of a transcript the server has confirmed persisted.
pub(all) struct AckedCursor {
  count : Int
  remote_count : Int
  last_external_id : String?
  prefix_fingerprint : String
} derive(Debug, Eq)

///|
/// Incremental slice to append for one flush (upstream AcknowledgedDelta).
/// `stop` is the exclusive end index and always equals the current
/// transcript length; `reset` marks a full resend after the acknowledged
/// prefix diverged.
pub(all) struct AckedDelta {
  start : Int
  stop : Int
  messages : Array[NmemThreadMessage]
  next : AckedCursor
  reset : Bool
} derive(Debug)

///|
/// Lowercase hex sha256 (upstream digest("hex")).
fn sha256_hex(input : Bytes) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(input))
}

///|
/// Fingerprint text of one message: the compact JSON of its wire shape
/// (upstream stableMessageFingerprint = JSON.stringify(message)).
fn message_fingerprint(m : NmemThreadMessage) -> String {
  m.to_wire_json().stringify()
}

///|
/// sha256 over the first `upto` messages, each encoded as
/// "{utf8 byte length}:{fingerprint text}" (upstream prefixFingerprint). The
/// length prefix keeps message boundaries unambiguous in the hash stream;
/// the length is the utf8 byte count, not the UTF-16 char count. `upto` is
/// clamped into [0, messages.length]; upstream callers never pass a
/// negative bound, and this port hashes the empty prefix for one.
fn prefix_fingerprint(
  messages : Array[NmemThreadMessage],
  upto : Int,
) -> String {
  let limit = if upto < 0 {
    0
  } else if upto > messages.length() {
    messages.length()
  } else {
    upto
  }
  let stream = StringBuilder()
  for i in 0..<limit {
    let value = message_fingerprint(messages[i])
    stream.write_string(@utf8.encode(value).length().to_string())
    stream.write_string(":")
    stream.write_string(value)
  }
  sha256_hex(@utf8.encode(stream.to_string()))
}

///|
/// metadata["external_id"] as upstream reads it (`stringValue(...) || ""`):
/// a trimmed non-blank string, or "" when absent, non-string, or blank.
fn message_external_id(m : NmemThreadMessage) -> String {
  if m.metadata.contains("external_id") {
    match m.metadata["external_id"] {
      Json::String(raw) => {
        let trimmed = raw.trim().to_owned()
        if trimmed == "" {
          ""
        } else {
          trimmed
        }
      }
      _ => ""
    }
  } else {
    ""
  }
}

///|
/// Select the incremental slice to append (upstream
/// selectAcknowledgedDelta). A cursor whose count is out of range, whose
/// last external id no longer matches, or whose prefix fingerprint diverged
/// (transcript rewritten or forked) forces a full reset: start 0 with
/// `reset=true`. `next` always describes the full transcript so it becomes
/// the acknowledged cursor once the flush succeeds.
pub fn select_acked_delta(
  messages : Array[NmemThreadMessage],
  cursor : AckedCursor?,
) -> AckedDelta {
  let mut start = match cursor {
    Some(acked) => acked.count
    None => 0
  }
  let mut reset = false
  let acknowledged_prefix = if start >= 0 && start <= messages.length() {
    prefix_fingerprint(messages, start)
  } else {
    ""
  }
  // The length guard mirrors upstream's short-circuiting `||`: when
  // start > messages.length the divergence probe (which indexes
  // messages[start - 1]) must not run; the range check below resets anyway.
  let diverged = if start > 0 && start <= messages.length() {
    match cursor {
      Some(acked) =>
        match acked.last_external_id {
          Some(last) =>
            message_external_id(messages[start - 1]) != last ||
            acknowledged_prefix != acked.prefix_fingerprint
          // Upstream compares the message's "" against an undefined
          // lastExternalId and treats it as a mismatch.
          None => true
        }
      None => true
    }
  } else {
    false
  }
  if start < 0 || start > messages.length() || diverged {
    start = 0
    reset = true
  }
  let stop = messages.length()
  let next : AckedCursor = {
    count: stop,
    remote_count: match cursor {
      Some(acked) => acked.remote_count
      None => stop
    },
    last_external_id: if stop > 0 {
      Some(message_external_id(messages[stop - 1]))
    } else {
      None
    },
    prefix_fingerprint: prefix_fingerprint(messages, stop),
  }
  { start, stop, messages: messages[start:stop].to_owned(), next, reset, }
}

///|
fn or_blank(value : String?) -> String {
  match value {
    Some(text) => text
    None => ""
  }
}

///|
/// Lane isolation key (upstream sessionSyncLaneKey): sha256 over the five
/// destination components joined by NUL, then NUL + thread id. Sync state
/// for different destinations or threads never mixes.
pub fn sync_lane_key(thread_id : String, config : NmemConfig) -> String {
  let destination = [
    config.api_url,
    or_blank(config.api_key),
    or_blank(config.space),
    or_blank(config.agent_id),
    or_blank(config.host_agent_id),
  ].join("\u{0}")
  sha256_hex(@utf8.encode(destination)) + "\u{0}" + thread_id
}
