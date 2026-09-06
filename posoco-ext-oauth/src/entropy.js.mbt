///|
/// entropy.js.mbt — js entropy probe via crypto.getRandomValues.
///
/// The probe returns hex ("" on any failure); decoding to Bytes stays in
/// MoonBit because the js FFI surface here is limited to Int/String. An empty
/// or malformed result selects the LCG fallback in entropy.mbt.

///|
extern "js" fn oauth_random_bytes_probe_js(n : Int) -> String =
  #| (n) => {
  #|   try {
  #|     const buf = new Uint8Array(n);
  #|     crypto.getRandomValues(buf);
  #|     let hex = "";
  #|     for (const b of buf) { hex += b.toString(16).padStart(2, "0"); }
  #|     return hex;
  #|   } catch { return ""; }
  #| }

///|
fn oauth_random_bytes_probe(n : Int) -> Bytes {
  bytes_from_hex(oauth_random_bytes_probe_js(n))
}

///|
/// Decode lowercase/uppercase hex to Bytes; empty Bytes on malformed input.
fn bytes_from_hex(hex : String) -> Bytes {
  if hex.length() == 0 || hex.length() % 2 != 0 {
    return Bytes::new(0)
  }
  let buf : Array[Byte] = []
  let mut hi = -1
  for ch in hex {
    match hex_nibble(ch) {
      Some(value) =>
        if hi < 0 {
          hi = value
        } else {
          buf.push(((hi << 4) | value).to_byte())
          hi = -1
        }
      None => return Bytes::new(0)
    }
  }
  if hi >= 0 {
    return Bytes::new(0)
  }
  Bytes::from_array(buf)
}

///|
fn hex_nibble(ch : Char) -> Int? {
  if ch >= '0' && ch <= '9' {
    Some(ch.to_int() - 48)
  } else if ch >= 'a' && ch <= 'f' {
    Some(ch.to_int() - 87)
  } else if ch >= 'A' && ch <= 'F' {
    Some(ch.to_int() - 55)
  } else {
    None
  }
}
