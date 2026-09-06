///|
/// Stable provider-side `prompt_cache_key` for a posoco session id:
/// `"posoco-" + session_id`, capped at 64 chars for unusual hosts. Pure and
/// deterministic — the same session id always yields the same key.
pub fn derive_prompt_cache_key(session_id : String) -> String {
  let full = "posoco-" + session_id
  if full.length() <= 64 {
    return full
  }
  let chars : Array[Char] = []
  for ch in full {
    if chars.length() >= 64 {
      break
    }
    chars.push(ch)
  }
  String::from_array(chars)
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
