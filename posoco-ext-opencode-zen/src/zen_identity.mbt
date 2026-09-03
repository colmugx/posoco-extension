///|
/// OpenCode Zen routing metadata.
///
/// Zen uses these OpenCode headers for session/provider affinity and request
/// attribution. Like the OpenCode CLI, one session id stays stable for the
/// whole process while every HTTP request gets a fresh request id; the values
/// honestly identify posoco rather than impersonating the CLI.

///|
let zen_session_cell : Ref[String?] = Ref::{ val: None, }

///|
/// Process-local session id, minted lazily on first use and reused by every
/// Zen request afterwards. Slot rebuilds (effort/model switches) and catalog
/// refreshes do not rotate it, matching the sticky `x-opencode-session`
/// semantics OpenCode relies on.
fn zen_session_id() -> String {
  match zen_session_cell.val {
    Some(id) => id
    None => {
      let id = "posoco_" + zen_random_uuid_v4()
      zen_session_cell.val = Some(id)
      id
    }
  }
}

///|
/// Build the per-request Zen headers: stable session id, fresh request id.
fn zen_request_headers() -> Map[String, String] {
  Map::from_array([
    ("x-opencode-project", "posoco"),
    ("x-opencode-session", zen_session_id()),
    ("x-opencode-request", zen_random_uuid_v4()),
    ("x-opencode-client", "posoco"),
    ("User-Agent", "posoco/opencode-zen"),
  ])
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
