///|
/// pkce.mbt — PKCE (Proof Key for Code Exchange) helpers per RFC 7636.
///
/// PKCE adds a layer of security to OAuth authorization code flow by
/// binding the authorization request to a verifier known only to the
/// client. Used by OpenAI's browser flow.

///|
/// A PKCE pair: the verifier is kept secret, the challenge is sent
/// in the authorization request.
pub(all) struct PkcePair {
  code_verifier : String // 43-128 char random string
  code_challenge : String // base64url(sha256(verifier))
  code_challenge_method : String // always "S256"
}

///|
/// The set of unreserved characters for PKCE verifiers (RFC 7636 §4.1).
let pkce_chars : Array[Char] = [
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P',
  'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f',
  'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v',
  'w', 'x', 'y', 'z', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '-', '.',
  '_', '~',
]

///|
/// Generate a PKCE pair with a random 64-character verifier.
pub fn generate_pkce() -> PkcePair {
  let verifier = random_pkce_string(64)
  let challenge = sha256_base64url(verifier)
  {
    code_verifier: verifier,
    code_challenge: challenge,
    code_challenge_method: "S256",
  }
}

///|
/// Generate a random string of the given length from the PKCE charset.
fn random_pkce_string(length : Int) -> String {
  let buf = StringBuilder::new()
  let seed = @async.now()
  let mut state = seed
  for i in 0..<length {
    // Simple LCG.
    state = state * 6364136223846793005L + 1442695040888963407L
    let idx = ((state >> 33).to_int() & 0x7FFFFFFF) % pkce_chars.length()
    buf.write_char(pkce_chars[idx])
  }
  buf.to_string()
}

///|
/// Compute SHA-256 of a string and return base64url encoding (no padding).
fn sha256_base64url(input : String) -> String {
  // @utf8.encode returns Bytes which implements ByteSource.
  let bytes : Bytes = @utf8.encode(input)
  let hash = @crypto.sha256(bytes)
  // hash is FixedArray[Byte] (32 bytes). Manually base64url-encode since
  // base64.encode requires BytesView and FixedArray doesn't convert cleanly.
  fixed_array_to_base64url(hash)
}

///|
/// Base64url alphabet (RFC 4648 §5, no padding).
let b64url_chars : Array[Char] = [
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P',
  'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f',
  'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v',
  'w', 'x', 'y', 'z', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '-', '_',
]

///|
/// Encode a FixedArray[Byte] to base64url string (no padding).
fn fixed_array_to_base64url(data : FixedArray[Byte]) -> String {
  let buf = StringBuilder::new()
  let len = data.length()
  let mut i = 0
  while i < len {
    let b0 = data[i].to_int()
    let b1 = if i + 1 < len { data[i + 1].to_int() } else { -1 }
    let b2 = if i + 2 < len { data[i + 2].to_int() } else { -1 }
    buf.write_char(b64url_chars[(b0 >> 2) & 0x3F])
    buf.write_char(
      b64url_chars[(((b0 & 0x03) << 4) | ((if b1 >= 0 { b1 } else { 0 }) >> 4)) &
      0x3F],
    )
    if b1 >= 0 {
      buf.write_char(
        b64url_chars[(
          ((b1 & 0x0F) << 2) | ((if b2 >= 0 { b2 } else { 0 }) >> 6)
        ) &
        0x3F],
      )
    }
    if b2 >= 0 {
      buf.write_char(b64url_chars[b2 & 0x3F])
    }
    i += 3
  }
  buf.to_string()
}
