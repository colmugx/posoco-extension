///|
/// OpenCode Zen routing metadata.
///
/// Zen uses these OpenCode headers for session/provider affinity and request
/// attribution. One session id stays stable for a kernel conversation, while
/// every HTTP request gets a fresh request id. Identity names posoco rather
/// than impersonating the CLI.

///|
/// OpenCode Go requires a stable gateway identity per conversation, not per
/// process. Using the kernel's session id also isolates concurrently running
/// Agents without mutable global bookkeeping. Request IDs stay fresh.

///|
/// Build the per-request OpenCode routing headers with the explicit kernel
/// conversation identity. Both Zen and Go use this helper across all wires;
/// never cache the session value at process or provider scope.
pub fn opencode_request_headers(
  client : String,
  session_id : String,
) -> Map[String, String] {
  Map::from_array([
    ("x-opencode-project", "posoco"),
    ("x-opencode-session", session_id),
    ("x-opencode-request", zen_random_uuid_v4()),
    ("x-opencode-client", client),
    ("User-Agent", "posoco/\{client}"),
  ])
}

///|
/// Internal test-facing helper for Zen's client identity.
fn zen_request_headers(session_id : String) -> Map[String, String] {
  opencode_request_headers("opencode-zen", session_id)
}

///|
/// Mint an opaque routing identifier for calls that carry no explicit
/// session fact (e.g. a bare decision call). The gateways use it for request
/// routing, never identity; it is not a cryptographic identifier.
pub fn opencode_session_uuid() -> String {
  zen_random_uuid_v4()
}

///|

///|
/// Mint a v4 UUID using the process RNG. The result is suitable for the
/// opaque routing identifiers expected by the Zen gateway; it is not intended
/// as a cryptographic identifier.
fn zen_random_uuid_v4() -> String {
  let rng = @random.Rand()
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
  let out = StringBuilder()
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
