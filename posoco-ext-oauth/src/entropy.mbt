///|
/// entropy.mbt — random bytes for PKCE verifiers and OAuth state.
///
/// `oauth_random_bytes` probes the backend entropy source (native: C
/// getentropy stub; js: crypto.getRandomValues) and falls back to a
/// time-seeded LCG only when the probe returns anything but exactly n bytes —
/// wasm/failed-probe fallback, not for credential backends.

///|
fn oauth_random_bytes(n : Int) -> Bytes {
  if n <= 0 {
    return Bytes::new(0)
  }
  let probed = oauth_random_bytes_probe(n)
  if probed.length() == n {
    probed
  } else {
    lcg_random_bytes(n)
  }
}

///|
/// OAuth state token: base64url (no padding) of 16 random bytes.
fn generate_state() -> String {
  bytes_to_base64url(oauth_random_bytes(16))
}

///|
/// Time-seeded LCG fallback for wasm and failed entropy probes.
fn lcg_random_bytes(n : Int) -> Bytes {
  let mut state = @async.now()
  let buf : Array[Byte] = []
  for _ in 0..<n {
    state = state * 6364136223846793005L + 1442695040888963407L
    buf.push(((state >> 33).to_int() & 0xFF).to_byte())
  }
  Bytes::from_array(buf)
}

///|
/// Wasm probe: no OS entropy source on this target; the empty result selects
/// the LCG fallback.
#cfg(not(any(target="native", target="js")))
fn oauth_random_bytes_probe(_n : Int) -> Bytes {
  Bytes::new(0)
}
