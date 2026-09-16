///|
/// Stable provider-side `prompt_cache_key` for a posoco session id.
///
/// Normal session ids keep the historical `"posoco-" + session_id` shape so
/// existing provider affinity is not churned unnecessarily. Oversized ids are
/// replaced with a versioned SHA-256-derived key instead of being truncated:
/// `posoco-v1-<48 lowercase hex chars>`. The hashed form is 58 chars, stays
/// below the 64-char provider limit, and two ids that share a long prefix do
/// not collapse to the same cache key.
pub fn derive_prompt_cache_key(session_id : String) -> String {
  let full = "posoco-" + session_id
  if full.length() <= 64 {
    return full
  }
  let digest = @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(session_id)))
  let chars : Array[Char] = []
  for ch in digest {
    if chars.length() >= 48 {
      break
    }
    chars.push(ch)
  }
  "posoco-v1-" + String::from_array(chars)
}

///|
/// Whether a provider error body explicitly rejects the `prompt_cache_key`
/// parameter: true only when the text contains BOTH "unsupported parameter"
/// AND "prompt_cache_key", case-insensitively. Empty bodies, bodies naming
/// only one phrase, and unrelated 400s never match.
pub fn is_prompt_cache_key_rejection(body_text : String) -> Bool {
  case_insensitive_contains(body_text, "unsupported parameter") &&
  case_insensitive_contains(body_text, "prompt_cache_key")
}
