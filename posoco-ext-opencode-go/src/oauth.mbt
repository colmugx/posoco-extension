///|
/// OpenCode Console account login: decode/select helpers only; transport lives
/// in `oauth_login_native_js.mbt`.

///|
/// Console origin and public device-flow client id.
let go_console_default_server : String = "https://opencode.ai/console"

///|
let go_console_client_id : String = "opencode-cli"

///|
/// Credential metadata keys; `api_base` is the versioned base from the
/// organisation's Console config.
let go_oauth_metadata_server : String = "server"

///|
let go_oauth_metadata_org_id : String = "org_id"

///|
let go_oauth_metadata_org_name : String = "org_name"

///|
let go_oauth_metadata_api_base : String = "api_base"

///|
let go_oauth_metadata_email : String = "email"

///|
/// Renewal margin before expiry; a refresh rotates the token pair.
let go_oauth_refresh_margin_secs : Int32 = 300

///|
/// The Console's device-authorization answer (RFC 8628 §3.2).
pub(all) struct GoDeviceAuth {
  device_code : String
  user_code : String
  /// Absolute; resolved from a possibly relative `verification_uri_complete`.
  verification_url : String
  expires_in : Int32
  interval : Int32
} derive(Eq, Debug)

///|
pub extend GoDeviceAuth with Eq::{not_equal, equal}

///|
pub extend GoDeviceAuth with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One grant.
pub(all) struct GoOAuthToken {
  access_token : String
  refresh_token : String
  expires_in : Int32
  /// Present when the Console scoped the grant to a workspace.
  org_id : String?
} derive(Eq, Debug)

///|
pub extend GoOAuthToken with Eq::{not_equal, equal}

///|
pub extend GoOAuthToken with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One poll verdict; `Failed` carries the Console's error code.
pub(all) enum GoTokenPoll {
  Pending
  SlowDown
  Granted(GoOAuthToken)
  Failed(String)
} derive(Eq, Debug)

///|
pub extend GoTokenPoll with Eq::{not_equal, equal}

///|
pub extend GoTokenPoll with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// A Console workspace.
pub(all) struct GoOrg {
  id : String
  name : String
} derive(Eq, Debug)

///|
pub extend GoOrg with Eq::{not_equal, equal}

///|
pub extend GoOrg with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Chosen workspace and its inference base.
pub(all) struct GoOrgChoice {
  org : GoOrg
  api_base : String?
} derive(Eq, Debug)

///|
pub extend GoOrgChoice with Eq::{not_equal, equal}

///|
pub extend GoOrgChoice with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// A stored grant, projected from the generic credential.
pub(all) struct GoOAuthSession {
  access_token : String
  refresh_token : String
  /// Epoch seconds; 0 = unknown.
  expires_at : Int32
  server : String
  org_id : String?
  api_base : String?
} derive(Eq, Debug)

///|
pub extend GoOAuthSession with Eq::{not_equal, equal}

///|
pub extend GoOAuthSession with @moonbitlang/core/debug.Debug::{to_repr}

///|
fn go_trim_trailing_slash(value : String) -> String {
  match value.strip_suffix("/") {
    Some(trimmed) => trimmed.to_owned()
    None => value
  }
}

///|
/// Absolute HTTP(S) URL with a host and no whitespace/control characters.
fn go_is_http_url(value : String) -> Bool {
  let rest = if value.has_prefix("https://") {
    value.exact_view(start=8)
  } else if value.has_prefix("http://") {
    value.exact_view(start=7)
  } else {
    return false
  }
  let host_end = match rest.find("/") {
    Some(index) => index
    None => rest.length()
  }
  if host_end == 0 {
    return false
  }
  for ch in rest {
    if ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' || ch.to_int() < 32 {
      return false
    }
  }
  true
}

///|
/// `scheme://host[:port]` of an absolute URL.
fn go_url_origin(value : String) -> String? {
  let scheme_end = match value.find("://") {
    Some(index) => index + 3
    None => return None
  }
  let rest = value.exact_view(start=scheme_end)
  let host_end = match rest.find("/") {
    Some(index) => index
    None => rest.length()
  }
  if host_end == 0 {
    return None
  }
  Some(value.exact_view(start=0, end=scheme_end + host_end).to_owned())
}

///|
/// Resolve the Console's verification link; `verification_uri_complete` may be
/// relative or root-relative.
pub fn go_resolve_verification_url(server : String, raw : String) -> String? {
  if raw.length() == 0 {
    return None
  }
  let url = if raw.has_prefix("https://") || raw.has_prefix("http://") {
    raw
  } else if raw.has_prefix("/") {
    match go_url_origin(server) {
      Some(origin) => origin + raw
      None => return None
    }
  } else {
    // A bare path must not smuggle a scheme into a URL a host may open.
    let head_end = match raw.find("/") {
      Some(index) => index
      None => raw.length()
    }
    if raw.exact_view(start=0, end=head_end).contains(":") {
      return None
    }
    go_trim_trailing_slash(server) + "/" + raw
  }
  if go_is_http_url(url) {
    Some(url)
  } else {
    None
  }
}

///|
fn go_json_string(value : Json?) -> String? {
  match value {
    Some(Json::String(text)) =>
      if text.length() > 0 {
        Some(text)
      } else {
        None
      }
    _ => None
  }
}

///|
fn go_json_object(value : Json?) -> Map[String, Json]? {
  match value {
    Some(Json::Object(fields)) => Some(fields)
    _ => None
  }
}

///|
fn go_json_positive_int(value : Json?, fallback : Int32) -> Int32 {
  match value {
    Some(Json::Number(number, ..)) => {
      let integer = number.to_int()
      if integer > 0 {
        integer
      } else {
        fallback
      }
    }
    _ => fallback
  }
}

///|
/// Decode the device-authorization answer.
pub fn parse_go_device_auth(
  server : String,
  payload : Json,
) -> Result[GoDeviceAuth, String] {
  let fields = match payload {
    Json::Object(fields) => fields
    _ => return Err("OpenCode Console device response must be an object")
  }
  let device_code = match go_json_string(fields.get("device_code")) {
    Some(value) => value
    None =>
      return Err("OpenCode Console device response is missing device_code")
  }
  let user_code = match go_json_string(fields.get("user_code")) {
    Some(value) => value
    None => return Err("OpenCode Console device response is missing user_code")
  }
  let raw_url = match go_json_string(fields.get("verification_uri_complete")) {
    Some(value) => value
    None =>
      match go_json_string(fields.get("verification_uri")) {
        Some(value) => value
        None =>
          return Err(
            "OpenCode Console device response is missing a verification URL",
          )
      }
  }
  let verification_url = match go_resolve_verification_url(server, raw_url) {
    Some(value) => value
    None =>
      return Err(
        "OpenCode Console device response returned an unusable verification URL",
      )
  }
  Ok({
    device_code,
    user_code,
    verification_url,
    expires_in: go_json_positive_int(fields.get("expires_in"), 600),
    interval: go_json_positive_int(fields.get("interval"), 5),
  })
}

///|
/// Decode one poll. `server_error`/5xx is transient: keep the code alive until
/// it expires.
pub fn parse_go_token_poll(status : Int32, payload : Json) -> GoTokenPoll {
  let fields = match payload {
    Json::Object(fields) => fields
    _ => return Failed("invalid_response")
  }
  let error = match go_json_string(fields.get("error")) {
    Some(value) => value
    None => ""
  }
  if error == "authorization_pending" {
    return Pending
  }
  if error == "slow_down" {
    return SlowDown
  }
  if error == "access_denied" {
    return Failed("access_denied")
  }
  if error == "expired_token" {
    return Failed("expired_token")
  }
  if error.length() > 0 {
    let transient = error == "server_error" ||
      error == "temporarily_unavailable" ||
      status >= 500 ||
      status == 429
    if transient {
      return Pending
    }
    return Failed(error)
  }
  if status >= 500 || status == 429 {
    return Pending
  }
  let access_token = match go_json_string(fields.get("access_token")) {
    Some(value) => value
    None => return Failed("missing_access_token")
  }
  let refresh_token = match go_json_string(fields.get("refresh_token")) {
    Some(value) => value
    None => return Failed("missing_refresh_token")
  }
  Granted({
    access_token,
    refresh_token,
    expires_in: go_json_positive_int(fields.get("expires_in"), 0),
    org_id: go_json_string(fields.get("org_id")),
  })
}

///|
/// Decode the Console's organisation list; entries without an id are dropped.
pub fn parse_go_orgs(payload : Json) -> Array[GoOrg] {
  let entries = match payload {
    Json::Array(items) => items
    _ => return []
  }
  let orgs : Array[GoOrg] = []
  for entry in entries {
    let fields = match entry {
      Json::Object(fields) => fields
      _ => continue
    }
    let id = match go_json_string(fields.get("id")) {
      Some(value) => value
      None => continue
    }
    let name = match go_json_string(fields.get("name")) {
      Some(value) => value
      None => ""
    }
    orgs.push({ id, name, })
  }
  orgs
}

///|
/// Fold the Console's OpenAI-compatible base (`.../go/openai/v1`) into this
/// plane's `.../go/v1`: chat appends `/chat/completions`, quota appends
/// `/usage`.
pub fn go_normalize_api_base(api : String) -> String? {
  if !go_is_http_url(api) {
    return None
  }
  let trimmed = go_trim_trailing_slash(api)
  if trimmed.has_suffix("/openai/v1") {
    let head = trimmed.exact_view(start=0, end=trimmed.length() - 10).to_owned()
    return Some(head + "/v1")
  }
  if trimmed.has_suffix("/v1") {
    return Some(trimmed)
  }
  Some(trimmed + "/v1")
}

///|
/// Read the Go inference base from a Console config payload: `providers` (v2)
/// or `config.provider` (legacy probe). Unknown shape reads as `None`.
pub fn parse_go_config_api(payload : Json) -> String? {
  let root = match payload {
    Json::Object(fields) => fields
    _ => return None
  }
  match go_json_object(root.get("providers")) {
    Some(providers) =>
      match go_json_object(providers.get("opencode-go")) {
        Some(entry) => {
          match go_json_object(entry.get("settings")) {
            Some(settings) =>
              match go_json_string(settings.get("baseURL")) {
                Some(value) =>
                  match go_normalize_api_base(value) {
                    Some(base) => return Some(base)
                    None => ()
                  }
                None => ()
              }
            None => ()
          }
          match go_json_string(entry.get("baseURL")) {
            Some(value) =>
              match go_normalize_api_base(value) {
                Some(base) => return Some(base)
                None => ()
              }
            None => ()
          }
        }
        None => ()
      }
    None => ()
  }
  match go_json_object(root.get("config")) {
    Some(config) =>
      match go_json_object(config.get("provider")) {
        Some(providers) =>
          match go_json_object(providers.get("opencode-go")) {
            Some(entry) =>
              match go_json_string(entry.get("api")) {
                Some(value) =>
                  match go_normalize_api_base(value) {
                    Some(base) => return Some(base)
                    None => ()
                  }
                None => ()
              }
            None => ()
          }
        None => ()
      }
    None => ()
  }
  None
}

///|
/// Pick the grant's workspace: the Console-scoped one, else the first whose
/// config carries Go. A fully successful probe with no Go entry fails the
/// login; a failed probe falls back to the first workspace by name.
pub fn choose_go_org(
  orgs : Array[GoOrg],
  preferred_id : String?,
  apis : Map[String, String],
  all_probes_ok : Bool,
) -> Result[GoOrgChoice, String] {
  let ordered = orgs.copy()
  ordered.sort_by((a, b) => {
    let by_name = a.name.lexical_compare(b.name)
    if by_name != 0 {
      by_name
    } else {
      a.id.lexical_compare(b.id)
    }
  })
  match preferred_id {
    Some(id) => {
      for org in ordered {
        if org.id == id {
          return Ok({ org, api_base: apis.get(id), })
        }
      }
      Err("OpenCode Console organisation not found: " + id)
    }
    None => {
      for org in ordered {
        match apis.get(org.id) {
          Some(api_base) => return Ok({ org, api_base: Some(api_base), })
          None => ()
        }
      }
      if all_probes_ok {
        return Err("this OpenCode account has no organisation with OpenCode Go")
      }
      match ordered.get(0) {
        Some(org) => Ok({ org, api_base: None, })
        None => Err("this OpenCode account has no organisations")
      }
    }
  }
}

///|
/// Project the generic credential into the Go plane's grant view. Anything
/// missing the access token is not a usable grant.
pub fn go_oauth_session(credential : @oauth.Credential) -> GoOAuthSession? {
  if credential.access_token.length() == 0 {
    return None
  }
  let server = match credential.metadata_value(go_oauth_metadata_server) {
    Some(value) => value
    None => go_console_default_server
  }
  let api_base = match credential.metadata_value(go_oauth_metadata_api_base) {
    Some(value) => go_normalize_api_base(value)
    None => None
  }
  Some({
    access_token: credential.access_token,
    refresh_token: credential.refresh_token,
    expires_at: credential.expires_at,
    server,
    org_id: credential.metadata_value(go_oauth_metadata_org_id),
    api_base,
  })
}

///|
/// Whether the access token is close enough to expiry to renew first.
pub fn go_oauth_is_expiring(session : GoOAuthSession, now_secs : Int32) -> Bool {
  session.expires_at > 0 &&
  now_secs >= session.expires_at - go_oauth_refresh_margin_secs
}

///|
/// Build the credential a fresh login stores; an unknown lifetime stays 0.
pub fn go_oauth_credential_from_login(
  token : GoOAuthToken,
  server : String,
  org~ : GoOrg,
  api_base~ : String? = None,
  email~ : String? = None,
  now_secs~ : Int32,
) -> @oauth.Credential {
  let metadata : Map[String, String] = Map::from_array([])
  metadata[go_oauth_metadata_server] = server
  metadata[go_oauth_metadata_org_id] = org.id
  if org.name.length() > 0 {
    metadata[go_oauth_metadata_org_name] = org.name
  }
  match api_base {
    Some(value) => metadata[go_oauth_metadata_api_base] = value
    None => ()
  }
  match email {
    Some(value) => metadata[go_oauth_metadata_email] = value
    None => ()
  }
  let expires_at = if token.expires_in > 0 {
    now_secs + token.expires_in
  } else {
    0
  }
  @oauth.Credential::Credential(
    access_token=token.access_token,
    refresh_token=token.refresh_token,
    expires_at~,
    metadata~,
  )
}

///|
/// Build the rotated credential; the refresh token always rotates, so callers
/// must persist the result.
pub fn go_oauth_refreshed_credential(
  previous : @oauth.Credential,
  token : GoOAuthToken,
  now_secs~ : Int32,
) -> @oauth.Credential {
  let metadata : Map[String, String] = Map::from_array([])
  for key, value in previous.metadata {
    metadata[key] = value
  }
  match token.org_id {
    Some(value) => metadata[go_oauth_metadata_org_id] = value
    None => ()
  }
  let expires_at = if token.expires_in > 0 {
    now_secs + token.expires_in
  } else {
    previous.expires_at
  }
  let refresh_token = if token.refresh_token.length() > 0 {
    token.refresh_token
  } else {
    previous.refresh_token
  }
  @oauth.Credential::Credential(
    access_token=token.access_token,
    refresh_token~,
    expires_at~,
    metadata~,
  )
}

///|
/// `x-opencode-org-id` for a grant; empty for API keys.
pub fn go_extra_headers(org_id : String?) -> Map[String, String] {
  let headers : Map[String, String] = Map::from_array([])
  match org_id {
    Some(value) =>
      if value.length() > 0 {
        headers["x-opencode-org-id"] = value
      }
    None => ()
  }
  headers
}

///|
/// Diagnostic text for a login/refresh failure (`OAuthError` has no `Show`).
pub fn go_oauth_error_text(err : @oauth.OAuthError) -> String {
  match err {
    @oauth.OAuthError::AuthPending => "auth_pending"
    @oauth.OAuthError::SlowDown => "slow_down"
    @oauth.OAuthError::AccessDenied => "access_denied"
    @oauth.OAuthError::ExpiredToken => "expired_token"
    @oauth.OAuthError::InvalidGrant => "invalid_grant"
    @oauth.OAuthError::HttpError(detail) => "http_error(" + detail + ")"
    @oauth.OAuthError::ParseError(detail) => "parse_error(" + detail + ")"
    @oauth.OAuthError::Cancelled => "cancelled"
  }
}
