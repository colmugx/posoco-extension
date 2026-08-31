///|
/// SSRF verdict for a parsed URL's host. HostBlocked carries a
/// human-readable reason string.
priv enum HostVerdict {
  HostAllowed
  HostBlocked(String)
}

///|
fn all_digits(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for i in 0..<s.length() {
    let u : UInt16 = s[i]
    if u < 48 || u > 57 {
      return false
    }
  }
  true
}

///|
fn all_hex(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for i in 0..<s.length() {
    let u : UInt16 = s[i]
    let ok = (u >= 48 && u <= 57) ||
      (u >= 97 && u <= 102) ||
      (u >= 65 && u <= 70)
    if !ok {
      return false
    }
  }
  true
}

///|
fn digits_val(s : String) -> Int {
  let mut v = 0
  for i in 0..<s.length() {
    v = v * 10 + (s[i].to_int() - 48)
  }
  v
}

///|
/// Strict dotted quad: four all-digit segments, each 0-255, no leading
/// zeros. Alternate inet_aton spellings (hex 0x7f000001, octal 0177.0.0.1,
/// short 127.1, integer 2130706433) deliberately do not parse as IPv4
/// here; check_host blocks them separately.
fn ipv4_parts(h : String) -> (Int, Int, Int, Int)? {
  let parts = split_char(h, 46)
  if parts.length() != 4 {
    return None
  }
  for part in parts {
    if !all_digits(part) {
      return None
    }
    if part.length() > 1 && part[0] == 48 {
      return None
    }
    if digits_val(part) > 255 {
      return None
    }
  }
  Some(
    (
      digits_val(parts[0]),
      digits_val(parts[1]),
      digits_val(parts[2]),
      digits_val(parts[3]),
    ),
  )
}

///|
/// Range classification of an IPv4 address; None means public.
fn ipv4_reason(a : Int, b : Int) -> String? {
  if a == 127 {
    Some("loopback address")
  } else if a == 10 {
    Some("private address")
  } else if a == 172 && b >= 16 && b <= 31 {
    Some("private address")
  } else if a == 192 && b == 168 {
    Some("private address")
  } else if a == 169 && b == 254 {
    Some("link-local address")
  } else if a == 0 {
    Some("unspecified address")
  } else {
    None
  }
}

///|
/// Classification only: "localhost." is judged as "localhost". A trailing
/// dot is legal DNS syntax but never changes the host.
fn strip_trailing_dot(h : String) -> String {
  if h.length() > 1 && h[h.length() - 1] == 46 {
    h[:h.length() - 1].to_owned()
  } else {
    h
  }
}

///|
/// IPv6 literals arrive here without brackets, lowercased. The
/// IPv4-embedded forms (::ffff:1.2.3.4, and the deprecated ::1.2.3.4) are
/// unwrapped and re-checked against the IPv4 ranges; hex spellings of
/// embedded IPv4 (::ffff:7f00:1) are blocked rather than decoded.
fn check_ipv6(h : String) -> HostVerdict {
  if h == "::1" {
    return HostBlocked("IPv6 loopback \{h}")
  }
  if h == "::" {
    return HostBlocked("IPv6 unspecified \{h}")
  }
  if h.has_prefix("fe80:") {
    return HostBlocked("IPv6 link-local \{h}")
  }
  if h.has_prefix("fc") || h.has_prefix("fd") {
    return HostBlocked("IPv6 ULA \{h}")
  }
  let embedded : String? = if h.has_prefix("::ffff:") {
    Some(h[7:].to_owned())
  } else if h.has_prefix("::") && h.contains(".") {
    Some(h[2:].to_owned())
  } else {
    None
  }
  match embedded {
    Some(inner) =>
      match ipv4_parts(inner) {
        Some((a, b, _, _)) =>
          match ipv4_reason(a, b) {
            Some(kind) => HostBlocked("\{kind} \{inner} (IPv4-embedded)")
            None => HostAllowed
          }
        None => HostBlocked("IPv4-embedded \{h}")
      }
    None => HostAllowed
  }
}

///|
/// Block hosts that name loopback/private/link-local targets directly, or
/// spell them in nonstandard numeric forms inet_aton still resolves. Bare
/// intranet names ("db01") and DNS rebinding need resolver-side defenses
/// and are out of scope for a lexical guard.
fn check_host(parsed : ParsedUrl) -> HostVerdict {
  let h = strip_trailing_dot(parsed.host)
  if h == "localhost" {
    return HostBlocked("localhost")
  }
  if h.has_suffix(".localhost") ||
    h.has_suffix(".local") ||
    h.has_suffix(".internal") {
    return HostBlocked("local suffix \{h}")
  }
  if h.contains(":") {
    return check_ipv6(h)
  }
  let parts = split_char(h, 46)
  for part in parts {
    if part.has_prefix("0x") || part.has_prefix("0X") {
      if all_hex(part[2:].to_owned()) {
        return HostBlocked("nonstandard numeric host \{h}")
      }
    }
  }
  let mut all_num = true
  for part in parts {
    if !all_digits(part) {
      all_num = false
      break
    }
  }
  if all_num {
    if parts.length() == 4 {
      let verdict : HostVerdict = match ipv4_parts(h) {
        Some((a, b, _, _)) =>
          match ipv4_reason(a, b) {
            Some(kind) => HostBlocked("\{kind} \{h}")
            None => HostAllowed
          }
        None => HostBlocked("nonstandard numeric host \{h}")
      }
      return verdict
    }
    // 1-3 all-numeric labels ("127.1", "10", "2130706433"): inet_aton
    // reads these as IPv4 addresses; no public hostname looks like this.
    // Five-plus labels fall through: numeric TLDs do not exist, so the
    // resolver simply fails.
    if parts.length() <= 3 {
      return HostBlocked("nonstandard numeric host \{h}")
    }
  }
  HostAllowed
}

///|
fn same_origin(a : ParsedUrl, b : ParsedUrl) -> Bool {
  a.scheme == b.scheme && a.host == b.host && a.port == b.port
}

///|
fn url_length_ok(s : String) -> Bool {
  s.length() <= 2000
}
