///|
/// Honest client identity for the Codex subscription backend: posoco reports
/// itself as `posoco` (never as codex_cli_rs) while mirroring the official
/// Codex CLI protocol header shape from codex-rs.

///|
/// The originator token sent as the `originator` header. Honest identity;
/// the Codex backend accepts third-party originators (pi, bub do the same).
let identity_originator : String = "posoco"

///|
/// Pure User-Agent assembly: "posoco/ext-openai ({platform} {release}; {arch})".
fn identity_user_agent(
  platform~ : String,
  release~ : String,
  arch~ : String,
) -> String {
  "posoco/ext-openai (" + platform + " " + release + "; " + arch + ")"
}

///|
/// User-Agent from live platform probes; empty probe segments never leak
/// through because each probe falls back to "unknown".
fn identity_user_agent_now() -> String {
  identity_user_agent(
    platform=identity_platform(),
    release=identity_os_release(),
    arch=identity_arch(),
  )
}

///|
/// Mint a v4 UUID with the process RNG; RFC 4122 version/variant nibbles are
/// patched so the textual shape matches `crypto.randomUUID()`. Not
/// cryptographically hardened.
fn identity_uuid_v4() -> String {
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

///|
let identity_installation_cell : Ref[String?] = Ref::{ val: None, }

///|
/// Process-stable installation id (`x-codex-installation-id`), minted once
/// per process and reused by every call afterwards.
fn identity_installation_id() -> String {
  match identity_installation_cell.val {
    Some(id) => id
    None => {
      let id = identity_uuid_v4()
      identity_installation_cell.val = Some(id)
      id
    }
  }
}

///|
let identity_fallback_session_cell : Ref[String?] = Ref::{ val: None, }

///|
/// Process-stable session id for call sites with no session scope.
fn identity_fallback_session_id() -> String {
  match identity_fallback_session_cell.val {
    Some(id) => id
    None => {
      let id = identity_uuid_v4()
      identity_fallback_session_cell.val = Some(id)
      id
    }
  }
}

///|
/// Official Codex CLI protocol header shape. `thread-id` is freshly minted
/// per call and `x-client-request-id` shares its value; `x-codex-window-id`
/// is the session id plus window 0; `Accept` follows `stream`.
fn codex_protocol_headers(
  session_id : String,
  stream : Bool,
) -> Map[String, String] {
  let thread_id = identity_uuid_v4()
  let accept = if stream { "text/event-stream" } else { "application/json" }
  Map::from_array([
    ("originator", identity_originator),
    ("User-Agent", identity_user_agent_now()),
    ("session-id", session_id),
    ("thread-id", thread_id),
    ("x-client-request-id", thread_id),
    ("x-codex-window-id", session_id + ":0"),
    ("Accept", accept),
  ])
}

///|
#cfg(not(any(target="native", target="js")))
fn identity_platform() -> String {
  "unknown"
}

///|
#cfg(not(any(target="native", target="js")))
fn identity_os_release() -> String {
  "unknown"
}

///|
#cfg(not(any(target="native", target="js")))
fn identity_arch() -> String {
  "unknown"
}
