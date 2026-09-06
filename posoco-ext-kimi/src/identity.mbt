///|
/// The Kimi OAuth host and managed `/coding/v1` endpoints only recognise
/// requests carrying the full kimi-code-cli User-Agent + X-Msh-* set;
/// without it `/models` is a 404.

///|
let kimi_identity_product : String = "kimi-code-cli"

///|
/// The version token reported to Kimi. Pinned to a recent kimi-code-cli
/// release; update when bumping the impersonation target.
let kimi_identity_version : String = "1.2.3"

///|
/// X-Msh-Platform: snake_case, unlike the User-Agent dash form.
let kimi_identity_platform : String = "kimi_code_cli"

///|
pub fn kimi_default_headers(device_id? : String) -> Map[String, String] {
  let id = match device_id {
    Some(value) => value
    None => kimi_random_uuid_v4()
  }
  Map::from_array([
    ("User-Agent", kimi_identity_product + "/" + kimi_identity_version),
    ("X-Msh-Platform", kimi_identity_platform),
    ("X-Msh-Version", kimi_identity_version),
    ("X-Msh-Device-Name", kimi_ascii_header(kimi_hostname())),
    ("X-Msh-Device-Model", kimi_ascii_header(kimi_device_model())),
    ("X-Msh-Os-Version", kimi_ascii_header(kimi_os_version())),
    ("X-Msh-Device-Id", kimi_ascii_header(id)),
  ])
}

///|
pub fn kimi_user_agent() -> String {
  kimi_identity_product + "/" + kimi_identity_version
}

///|
fn kimi_ascii_header(value : String, fallback? : String = "unknown") -> String {
  let buf = StringBuilder()
  for ch in value {
    let code = ch.to_int()
    if code >= 0x20 && code <= 0x7e {
      buf.write_char(ch)
    }
  }
  let cleaned = buf.to_string().trim().to_owned()
  if cleaned.length() > 0 {
    cleaned
  } else {
    fallback
  }
}

///|
/// Process-RNG v4 UUID; not cryptographically hardened.
fn kimi_random_uuid_v4() -> String {
  let rng = @random.Rand::new()
  // 16 random bytes; version (byte 6) and variant (byte 8) are patched after.
  let bytes : Array[Byte] = []
  for _i in 0..<16 {
    bytes.push(rng.uint(limit=256).to_byte())
  }
  bytes[6] = (0x40).to_byte() | (bytes[6] & 0x0f)
  bytes[8] = (0x80).to_byte() | (bytes[8] & 0x3f)
  // Hex lookup as a Char array to avoid String-index UInt16/Char mismatch.
  let hex : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
  ]
  // Group byte offsets for the canonical 8-4-4-4-12 textual layout.
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
#cfg(not(any(target="native", target="js")))
fn kimi_hostname() -> String {
  ""
}

///|
#cfg(not(any(target="native", target="js")))
fn kimi_device_model() -> String {
  ""
}

///|
#cfg(not(any(target="native", target="js")))
fn kimi_os_version() -> String {
  ""
}
