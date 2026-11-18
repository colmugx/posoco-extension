///|
/// Configuration is host-owned. Never put the API token in tool schemas,
/// model-visible outcomes, debug output, or request URLs.
pub struct KitesurfConfig {
  account_id : String
  api_token : String
  timeout_ms : Int32
  max_output_chars : Int32
  allowed_hosts : Array[String]
}

///|
/// allowed_hosts is an optional exact-host allowlist (no wildcard matching).
/// Empty means the host has not configured an allowlist; applications handling
/// untrusted URLs should set it. Redirect destinations are not checked here.
pub fn KitesurfConfig::KitesurfConfig(
  account_id~ : String,
  api_token~ : String,
  timeout_ms~ : Int32 = 30_000,
  max_output_chars~ : Int32 = 24_000,
  allowed_hosts~ : Array[String] = [],
) -> KitesurfConfig {
  { account_id, api_token, timeout_ms, max_output_chars, allowed_hosts, }
}

///|
/// Reject malformed configuration without embedding any secret value.
fn config_error(self : KitesurfConfig) -> String? {
  if self.account_id.trim().length() == 0 {
    return Some("kitesurf: account_id must not be empty")
  }
  // The Cloudflare account ID is a hex identifier; treating other characters
  // as invalid also prevents URL path/query injection.
  if self.account_id.length() != 32 {
    return Some("kitesurf: account_id must be 32 hexadecimal characters")
  }
  for ch in self.account_id {
    if !((ch >= '0' && ch <= '9') ||
      (ch >= 'a' && ch <= 'f') ||
      (ch >= 'A' && ch <= 'F')) {
      return Some("kitesurf: account_id must be hexadecimal")
    }
  }
  if self.api_token.trim().length() == 0 {
    return Some("kitesurf: api_token must not be empty")
  }
  if self.timeout_ms <= 0 {
    return Some("kitesurf: timeout_ms must be positive")
  }
  if self.max_output_chars <= 0 {
    return Some("kitesurf: max_output_chars must be positive")
  }
  None
}

///|
/// Only publicly addressable http(s) hostnames are accepted at this boundary.
/// This is a conservative syntactic check, NOT a DNS, redirect, or network
/// egress guarantee. Hosts processing untrusted URLs should set allowed_hosts
/// and apply their own Cloudflare-side egress controls as appropriate.
fn target_error(self : KitesurfConfig, url : String) -> String? {
  let rest = if url.has_prefix("https://") {
    url[8:].to_owned()
  } else if url.has_prefix("http://") {
    url[7:].to_owned()
  } else {
    return Some("kitesurf: URL must use http:// or https://")
  }
  let mut authority = rest
  for separator in ["/", "?", "#"] {
    match authority.find(separator) {
      Some(index) => authority = authority[:index].to_owned()
      None => ()
    }
  }
  let host = authority.to_lower().to_owned()
  if host.length() == 0 ||
    host.contains("@") ||
    host.contains("\\") ||
    host.contains(":") ||
    host.contains("%") ||
    host.contains(" ") ||
    host.contains("..") ||
    !host.contains(".") {
    return Some("kitesurf: URL must contain a public hostname without credentials or port")
  }
  if host == "localhost" ||
    host.has_suffix(".localhost") ||
    host.has_suffix(".local") ||
    host.has_suffix(".internal") ||
    host.has_suffix(".test") ||
    host.has_suffix(".invalid") {
    return Some("kitesurf: local hostnames are not allowed")
  }
  let mut numeric = true
  for ch in host {
    if !((ch >= '0' && ch <= '9') || ch == '.') {
      numeric = false
    }
  }
  if numeric {
    return Some("kitesurf: IP literal targets are not allowed")
  }
  if !self.allowed_hosts.is_empty() {
    let mut allowed = false
    for candidate in self.allowed_hosts {
      if candidate.to_lower() == host {
        allowed = true
        break
      }
    }
    if !allowed {
      return Some("kitesurf: target hostname is not in allowed_hosts")
    }
  }
  None
}
