///|
/// Minimal RFC 3986 URL subset for the webfetch pipeline: absolute http/https
/// URLs only, no userinfo, optional explicit port, path + query, fragment
/// dropped. Pure functions — this file is the shared seam between url_guard
/// (host validation) and html_to_markdown (link absolutization). M2 owns
/// hardening + tests; other files treat it as a read-only dependency.
priv struct ParsedUrl {
  scheme : String // lowercase "http" | "https"
  host : String // lowercase; IPv6 literal without brackets
  port : Int // explicit port or scheme default
  path : String // starts with "/" (default "/")
  query : String // without '?', "" if none
}

///|
fn default_port(scheme : String) -> Int {
  if scheme == "https" {
    443
  } else {
    80
  }
}

///|
fn parse_port(digits : String) -> Int? {
  if digits.length() == 0 || digits.length() > 5 {
    return None
  }
  let mut v = 0
  for i in 0..<digits.length() {
    let u : UInt16 = digits[i]
    if u < 48 || u > 57 {
      return None
    }
    v = v * 10 + (u.to_int() - 48)
  }
  if v >= 1 && v <= 65535 {
    Some(v)
  } else {
    None
  }
}

///|
/// Characters accepted in a non-literal host (already lowercased): letters,
/// digits, '-', '.', '_'. Percent-encoded and non-ASCII hosts are rejected:
/// the fetch layer never IDN-decodes, so accepting exotic spellings would
/// only smuggle them past the host guard.
fn regname_ok(host : String) -> Bool {
  if host.length() == 0 {
    return false
  }
  for i in 0..<host.length() {
    let u : UInt16 = host[i]
    let ok = (u >= 97 && u <= 122) ||
      (u >= 48 && u <= 57) ||
      u == 45 ||
      u == 46 ||
      u == 95
    if !ok {
      return false
    }
  }
  true
}

///|
/// Body of a bracketed IPv6 literal (already lowercased): hex digits, ':'
/// and '.' for embedded IPv4; at least one ':' required.
fn ipv6_literal_ok(inner : String) -> Bool {
  if inner.length() == 0 || !inner.contains(":") {
    return false
  }
  for i in 0..<inner.length() {
    let u : UInt16 = inner[i]
    let ok = (u >= 48 && u <= 57) || (u >= 97 && u <= 102) || u == 58 || u == 46
    if !ok {
      return false
    }
  }
  true
}

///|
fn parse_url(s : String) -> ParsedUrl? {
  // Fragment first: everything after '#' is dropped.
  let nofrag : String = match s.find("#") {
    Some(i) => s[:i].to_owned()
    None => s
  }
  guard nofrag.find("://") is Some(p) else { return None }
  let scheme : String = nofrag[:p].to_owned().to_lower()
  if scheme != "http" && scheme != "https" {
    return None
  }
  let after : String = nofrag[p + 3:].to_owned()
  // Authority ends at the first '/', '?', or '#'.
  let mut end = after.length()
  for i in 0..<after.length() {
    let u : UInt16 = after[i]
    if u == 47 || u == 63 || u == 35 {
      // '/', '?', '#'
      end = i
      break
    }
  }
  let authority : String = after[:end].to_owned()
  let tail : String = after[end:].to_owned()
  if authority.contains("@") {
    return None // userinfo rejected
  }
  let host_port : (String, Int) = if authority.has_prefix("[") {
    // IPv6 literal: [addr] with optional ":port" after ']'
    guard authority.find("]") is Some(close) else { return None }
    let inner : String = authority[1:close].to_owned()
    if inner.length() == 0 {
      return None
    }
    let rest : String = authority[close + 1:].to_owned()
    if rest.length() == 0 {
      (inner.to_lower(), default_port(scheme))
    } else if rest.has_prefix(":") && rest.length() > 1 {
      let digits : String = rest[1:].to_owned()
      guard parse_port(digits) is Some(pt) else { return None }
      (inner.to_lower(), pt)
    } else {
      return None
    }
  } else {
    match authority.find(":") {
      Some(c) => {
        let h : String = authority[:c].to_owned()
        if h.length() == 0 {
          return None
        }
        let digits : String = authority[c + 1:].to_owned()
        guard parse_port(digits) is Some(pt) else { return None }
        (h.to_lower(), pt)
      }
      None => {
        if authority.length() == 0 {
          return None
        }
        (authority.to_lower(), default_port(scheme))
      }
    }
  }
  let (host, port) = host_port
  if host.contains(":") {
    guard ipv6_literal_ok(host) else { return None }
  } else {
    guard regname_ok(host) else { return None }
  }
  // tail is "/path", "?query", "", or "/path?query"
  let path_query : (String, String) = match tail.find("?") {
    Some(qi) => {
      let pv : String = tail[:qi].to_owned()
      let qv : String = tail[qi + 1:].to_owned()
      (if pv.length() == 0 { "/" } else { pv }, qv)
    }
    None => (if tail.length() == 0 { "/" } else { tail }, "")
  }
  let (path, query) = path_query
  Some(ParsedUrl::{ scheme, host, port, path, query, })
}

///|
fn ParsedUrl::host_display(self : ParsedUrl) -> String {
  if self.host.contains(":") {
    "[\{self.host}]"
  } else {
    self.host
  }
}

///|
fn ParsedUrl::origin_string(self : ParsedUrl) -> String {
  let host = self.host_display()
  if self.port == default_port(self.scheme) {
    "\{self.scheme}://\{host}"
  } else {
    "\{self.scheme}://\{host}:\{self.port}"
  }
}

///|
fn ParsedUrl::to_url_string(self : ParsedUrl) -> String {
  let origin = self.origin_string()
  if self.query.length() == 0 {
    "\{origin}\{self.path}"
  } else {
    "\{origin}\{self.path}?\{self.query}"
  }
}

///|
/// Manual split (String::split is a lazy Iter of views in this core
/// version; callers here want indexable owned segments).
fn split_char(s : String, sep : UInt16) -> Array[String] {
  let parts : Array[String] = []
  let mut start = 0
  for i in 0..<s.length() {
    if s[i] == sep {
      parts.push(s[start:i].to_owned())
      start = i + 1
    }
  }
  parts.push(s[start:].to_owned())
  parts
}

///|
/// RFC 3986 remove_dot_segments. Precondition: p starts with "/" (all
/// callers pass rooted paths). Interior empty segments and a trailing
/// slash survive; dot segments at the end leave a trailing slash, so
/// "/a/b/.." and "/a/b/../" both reduce to "/a/".
fn normalize_path(p : String) -> String {
  let raw = split_char(p, 47)
  let out : Array[String] = []
  let last = raw.length() - 1
  for i, seg in raw {
    if i == 0 {
      continue // leading "" from the root slash
    }
    if seg == ".." {
      if out.length() > 0 {
        ignore(out.pop())
      }
    } else if seg == "." {
      continue
    } else if seg == "" {
      if i < last {
        out.push("") // interior "//" survives RFC normalization
      }
    } else {
      out.push(seg)
    }
  }
  let trailing = last > 0 &&
    (raw[last] == "" || raw[last] == "." || raw[last] == "..")
  let joined = StringBuilder()
  joined.write_char('/')
  for i, seg in out {
    if i > 0 {
      joined.write_char('/')
    }
    joined.write_string(seg)
  }
  if trailing && out.length() > 0 {
    joined.write_char('/')
  }
  joined.to_string()
}

///|
/// Lowercase scheme prefix of a reference ("" when the reference has no
/// scheme — i.e. it is relative). Terminators follow RFC 3986: '/', '?', '#'.
fn ref_scheme(reference : String) -> String {
  for i in 0..<reference.length() {
    let u : UInt16 = reference[i]
    if u == 58 {
      // ':'
      return reference[:i].to_owned().to_lower()
    }
    if u == 47 || u == 63 || u == 35 {
      // '/', '?', '#'
      return ""
    }
  }
  ""
}

///|
/// parse_url keeps the path verbatim; references resolved through join get
/// their dot segments folded per RFC 3986.
fn ParsedUrl::normalized(self : ParsedUrl) -> ParsedUrl {
  ParsedUrl::{
    scheme: self.scheme,
    host: self.host,
    port: self.port,
    path: normalize_path(self.path),
    query: self.query,
  }
}

///|
/// Reference resolution for Location headers and HTML links. Foreign-scheme
/// absolute references (mailto:, javascript:, …) return the base unchanged so
/// callers can drop them. Fragments are dropped; a fragment-only reference
/// resolves to the base itself.
fn ParsedUrl::join(self : ParsedUrl, reference : String) -> ParsedUrl {
  let trimmed : String = reference.trim().to_owned()
  let r : String = match trimmed.find("#") {
    Some(i) => trimmed[:i].to_owned()
    None => trimmed
  }
  if r.length() == 0 {
    return self
  }
  let sch = ref_scheme(r)
  if sch != "" {
    if sch == "http" || sch == "https" {
      match parse_url(r) {
        Some(u) => return u.normalized()
        None => return self
      }
    }
    return self
  }
  if r.has_prefix("//") {
    match parse_url("\{self.scheme}:\{r}") {
      Some(u) => return u.normalized()
      None => return self
    }
  }
  // Split the reference into path and query parts.
  let rq : (String, String) = match r.find("?") {
    Some(i) => (r[:i].to_owned(), r[i + 1:].to_owned())
    None => (r, "")
  }
  let (rp, qv) = rq
  if rp.has_prefix("/") {
    return ParsedUrl::{
      scheme: self.scheme,
      host: self.host,
      port: self.port,
      path: normalize_path(rp),
      query: qv,
    }
  }
  if rp.length() == 0 {
    return ParsedUrl::{
      scheme: self.scheme,
      host: self.host,
      port: self.port,
      path: self.path,
      query: qv,
    }
  }
  // Relative path: resolve against the base path's directory.
  let mut cut = 0
  for i in 0..<self.path.length() {
    if self.path[i] == '/' {
      cut = i + 1
    }
  }
  let base_dir : String = self.path[:cut].to_owned()
  ParsedUrl::{
    scheme: self.scheme,
    host: self.host,
    port: self.port,
    path: normalize_path("\{base_dir}\{rp}"),
    query: qv,
  }
}

///|
/// String-in/string-out absolutization used by html_to_markdown. Returns the
/// base unchanged when the base does not parse.
fn resolve_ref(base : String, reference : String) -> String {
  match parse_url(base) {
    Some(b) => b.join(reference).to_url_string()
    None => base
  }
}
