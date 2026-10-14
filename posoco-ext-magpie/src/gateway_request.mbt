///|
/// gateway_request.mbt — pure request-building helpers.
///
/// Everything here is a pure function of the configuration: URL assembly,
/// loopback detection, token selection, and header construction. Keeping the
/// request shape pure makes the auth boundary testable without any transport
/// and keeps credential handling in exactly one place.

///|
/// `true` when the URL's host is a loopback address (`127.0.0.1`,
/// `localhost`, `::1`). Only loopback endpoints may use Magpie's local
/// application-token convention; anything else is remote and needs an
/// explicitly configured gateway credential.
pub fn is_loopback_url(url : String) -> Bool {
  let authority = match url_authority(url) {
    Some(authority) => authority
    None => return false
  }
  // Strip userinfo, then the port. Bracketed IPv6 literals keep their
  // brackets so `[::1]:3425` compares as `[::1]`.
  let without_user = match authority.rev_find("@") {
    Some(idx) => authority[idx + 1:].to_owned()
    None => authority
  }
  let host = if without_user.has_prefix("[") {
    match without_user.find("]") {
      Some(idx) => without_user[:idx + 1].to_owned()
      None => without_user
    }
  } else {
    match without_user.find(":") {
      Some(idx) => without_user[:idx].to_owned()
      None => without_user
    }
  }
  let lowered = host.to_lower()
  lowered is "127.0.0.1" ||
  lowered is "localhost" ||
  lowered is "::1" ||
  lowered is "[::1]"
}

///|
/// `scheme://authority` of an absolute URL, `None` when the shape does not
/// match. The authority keeps its port; userinfo is left for callers to
/// strip.
fn url_authority(url : String) -> String? {
  let marker = "://"
  guard url.contains(marker) else { return None }
  let rest = match url.find(marker) {
    Some(idx) => url[idx + marker.length():].to_owned()
    None => return None
  }
  match rest.find("/") {
    Some(idx) => Some(rest[:idx].to_owned())
    None => Some(rest)
  }
}

///|
/// Absolute URL for a gateway path such as `/api/hello` or `/v1/models`.
/// The configured base URL carries no trailing slash (normalized at
/// construction), so simple concatenation is exact.
pub fn gateway_url(config : MagpieConfig, path : String) -> String {
  config.base_url + path
}

///|
/// The credential to present, or `None` when the endpoint is remote and no
/// credential is configured. Order of precedence: configured credential
/// first; on loopback, Magpie's documented local application token; never
/// the local token on a remote endpoint.
pub fn effective_token(config : MagpieConfig) -> String? {
  match config.credential {
    Some(credential) => Some(credential)
    None =>
      if is_loopback_url(config.base_url) {
        Some(LOCAL_APP_TOKEN)
      } else {
        None
      }
  }
}

///|
/// Headers for one gateway request: the Bearer credential, a JSON accept,
/// and an application User-Agent naming the app, as Magpie's integration
/// guide documents. Built fresh for every request; the transport never
/// stores credentials.
pub fn gateway_headers(token : String) -> Map[String, String] {
  Map::from_array([
    ("Authorization", "Bearer \{token}"),
    ("Accept", "application/json"),
    ("User-Agent", "magpie-posoco (posoco-ext-magpie)"),
  ])
}
