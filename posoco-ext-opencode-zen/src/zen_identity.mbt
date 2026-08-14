///|
/// OpenCode Zen routing metadata.
///
/// Zen uses these OpenCode headers for session/provider affinity and request
/// attribution. Posoco deliberately identifies itself as `posoco` rather than
/// impersonating the OpenCode CLI.

///|
/// Build a fresh OpenCode-compatible request id. A new value is generated for
/// every HTTP request while the session id remains stable for the lifetime of
/// the model port.
pub fn zen_request_headers(session_id : String) -> Map[String, String] {
  Map::from_array([
    ("x-opencode-project", "posoco"),
    ("x-opencode-session", session_id),
    ("x-opencode-request", zen_random_uuid_v4()),
    ("x-opencode-client", "posoco"),
    ("User-Agent", "posoco/opencode-zen"),
  ])
}

///|
/// Process-local session id. It is intentionally created once when the Zen
/// catalog slot is built and reused by every request from that slot, matching
/// the sticky-session semantics OpenCode uses with `x-opencode-session`.
pub fn zen_new_session_id() -> String {
  "posoco_" + zen_random_uuid_v4()
}

///|
/// Mint a v4 UUID using the process RNG. The result is suitable for the
/// opaque routing identifiers expected by the Zen gateway; it is not intended
/// as a cryptographic identifier.
fn zen_random_uuid_v4() -> String {
  let rng = @random.Rand::new()
  let bytes : Array[Byte] = []
  for _i in 0..<16 {
    bytes.push(rng.uint(limit=256).to_byte())
  }
  bytes[6] = (0x40).to_byte() | (bytes[6] & 0x0f)
  bytes[8] = (0x80).to_byte() | (bytes[8] & 0x3f)
  let hex : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
  ]
  let group_sizes = [4, 2, 2, 2, 6]
  let out = StringBuilder::new()
  let mut idx = 0
  for i, size in group_sizes {
    if i > 0 {
      out.write_char('-')
    }
    for _j in 0..<size {
      let b = bytes[idx].to_int()
      out.write_char(hex[(b >> 4) & 0x0f])
      out.write_char(hex[b & 0x0f])
      idx += 1
    }
  }
  out.to_string()
}
