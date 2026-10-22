///|
/// Native+wasm+js: Console login/refresh transport. Decoding and workspace
/// choice live in `oauth.mbt`.

///|
fn go_now_secs() -> Int32 {
  (@async.now() / 1000L).to_int()
}

///|
fn go_console_url(server : String, path : String) -> String {
  go_trim_trailing_slash(server) + path
}

///|
async fn go_console_post_json(
  url : String,
  body : Json,
) -> (Int32, String) raise @oauth.OAuthError {
  let headers : @http.Headers = {
    "Content-Type": "application/json",
    "Accept": "application/json",
    "User-Agent": "posoco/opencode-go",
  }
  let (response, body_data) = @async.with_timeout(30000, () => {
    @http.post(url, body.stringify(), headers~)
  }) catch {
    @async.TimeoutError =>
      raise @oauth.OAuthError::HttpError(
        "OpenCode Console request timed out: " + url,
      )
    err =>
      raise @oauth.OAuthError::HttpError(
        "OpenCode Console request failed: " + err.to_string(),
      )
  }
  let text = body_data.text() catch {
    _ =>
      raise @oauth.OAuthError::ParseError(
        "OpenCode Console response is not UTF-8: " + url,
      )
  }
  (response.code, text)
}

///|
async fn go_console_get_json(
  url : String,
  access_token : String,
  org_id : String?,
) -> (Int32, String) raise @oauth.OAuthError {
  let headers : @http.Headers = {
    "Authorization": "Bearer " + access_token,
    "Accept": "application/json",
    "User-Agent": "posoco/opencode-go",
  }
  match org_id {
    Some(value) =>
      if value.length() > 0 {
        headers[@http.CaseInsensitiveString("x-org-id")] = value
      }
    None => ()
  }
  let (response, body_data) = @async.with_timeout(15000, () => {
    @http.get(url, headers~)
  }) catch {
    @async.TimeoutError =>
      raise @oauth.OAuthError::HttpError(
        "OpenCode Console request timed out: " + url,
      )
    err =>
      raise @oauth.OAuthError::HttpError(
        "OpenCode Console request failed: " + err.to_string(),
      )
  }
  let text = body_data.text() catch {
    _ =>
      raise @oauth.OAuthError::ParseError(
        "OpenCode Console response is not UTF-8: " + url,
      )
  }
  (response.code, text)
}

///|
fn go_parse_json_body(
  url : String,
  text : String,
) -> Json raise @oauth.OAuthError {
  @json.parse(text) catch {
    _ =>
      raise @oauth.OAuthError::ParseError(
        "OpenCode Console JSON parse failed: " + url,
      )
  }
}

///|
fn go_poll_failed_error(code : String) -> @oauth.OAuthError {
  match code {
    "access_denied" => @oauth.OAuthError::AccessDenied
    "expired_token" => @oauth.OAuthError::ExpiredToken
    "invalid_grant" => @oauth.OAuthError::InvalidGrant
    other =>
      @oauth.OAuthError::ParseError(
        "OpenCode Console authorization failed: " + other,
      )
  }
}

///|
/// Request a device code; `supports_org_scope` lets the Console bind the grant
/// to the signed-in workspace.
async fn go_oauth_device_start(
  server : String,
) -> GoDeviceAuth raise @oauth.OAuthError {
  let url = go_console_url(server, "/auth/device/code")
  let body : Json = Json::object(
    Map::from_array([
      ("client_id", Json::string(go_console_client_id)),
      ("supports_org_scope", Json::boolean(true)),
    ]),
  )
  let (status, text) = go_console_post_json(url, body)
  let payload = go_parse_json_body(url, text)
  if status < 200 || status >= 300 {
    raise @oauth.OAuthError::HttpError(
      "OpenCode Console device request failed (status=\{status}, body=\{text})",
    )
  }
  match parse_go_device_auth(server, payload) {
    Ok(device) => device
    Err(message) => raise @oauth.OAuthError::ParseError(message)
  }
}

///|
/// Poll until approved, expired, or cancelled; `slow_down` adds five seconds.
async fn go_oauth_poll(
  server : String,
  device : GoDeviceAuth,
  interaction : &@oauth.AuthInteraction,
) -> GoOAuthToken raise @oauth.OAuthError {
  let url = go_console_url(server, "/auth/device/token")
  let deadline = go_now_secs() + device.expires_in
  let mut interval = device.interval
  for ;; {
    if interaction.is_cancelled() {
      raise @oauth.OAuthError::Cancelled
    }
    if go_now_secs() >= deadline {
      raise @oauth.OAuthError::ExpiredToken
    }
    @async.sleep(interval * 1000)
    let body : Json = Json::object(
      Map::from_array([
        (
          "grant_type",
          Json::string("urn:ietf:params:oauth:grant-type:device_code"),
        ),
        ("device_code", Json::string(device.device_code)),
        ("client_id", Json::string(go_console_client_id)),
      ]),
    )
    let (status, text) = go_console_post_json(url, body)
    let payload = go_parse_json_body(url, text)
    match parse_go_token_poll(status, payload) {
      Granted(token) => return token
      Pending => ()
      SlowDown => interval = interval + 5
      Failed(code) => raise go_poll_failed_error(code)
    }
  }
  abort("unreachable")
}

///|
/// The account e-mail, informational; a failure is not a login failure.
async fn go_oauth_account_email(
  server : String,
  access_token : String,
) -> String? noraise {
  let url = go_console_url(server, "/api/user")
  let (status, text) = go_console_get_json(url, access_token, None) catch {
    _ => return None
  }
  if status < 200 || status >= 300 {
    return None
  }
  let payload = go_parse_json_body(url, text) catch { _ => return None }
  match payload {
    Json::Object(fields) =>
      match fields.get("email") {
        Some(Json::String(value)) => Some(value)
        _ => None
      }
    _ => None
  }
}

///|
/// One workspace's config probe: whether it answered, and the Go base it named.
priv struct GoOrgProbe {
  api : String?
  ok : Bool
}

///|
async fn go_oauth_probe_config_path(
  server : String,
  access_token : String,
  org_id : String,
  path : String,
) -> GoOrgProbe noraise {
  let url = go_console_url(server, path)
  let (status, text) = go_console_get_json(url, access_token, Some(org_id)) catch {
    _ => return { api: None, ok: false, }
  }
  if status < 200 || status >= 300 {
    return { api: None, ok: false, }
  }
  let payload = go_parse_json_body(url, text) catch {
    _ => return { api: None, ok: false, }
  }
  { api: parse_go_config_api(payload), ok: true, }
}

///|
/// Config probe: `/api/config` first, `/api/v2/config` when it is absent.
async fn go_oauth_probe_org(
  server : String,
  access_token : String,
  org : GoOrg,
) -> GoOrgProbe noraise {
  let primary = go_oauth_probe_config_path(
    server,
    access_token,
    org.id,
    "/api/config",
  )
  if primary.ok {
    return primary
  }
  go_oauth_probe_config_path(server, access_token, org.id, "/api/v2/config")
}

///|
/// Device login: code, approval, workspace selection, credential.
pub async fn go_oauth_login(
  interaction : &@oauth.AuthInteraction,
  server~ : String = go_console_default_server,
) -> @oauth.Credential raise @oauth.OAuthError {
  let device = go_oauth_device_start(server)
  interaction.notify(
    @oauth.AuthMessage::DeviceCode(device.verification_url, device.user_code),
  )
  let token = go_oauth_poll(server, device, interaction)
  let email = go_oauth_account_email(server, token.access_token)
  let orgs_url = go_console_url(server, "/api/orgs")
  let (status, text) = go_console_get_json(orgs_url, token.access_token, None)
  if status < 200 || status >= 300 {
    raise @oauth.OAuthError::HttpError(
      "OpenCode Console organisation listing failed (status=\{status}, body=\{text})",
    )
  }
  let payload = go_parse_json_body(orgs_url, text)
  let orgs = parse_go_orgs(payload)
  if orgs.is_empty() {
    raise @oauth.OAuthError::ParseError(
      "OpenCode Console returned no organisations for this account",
    )
  }
  let apis : Map[String, String] = Map::from_array([])
  let mut all_probes_ok = true
  for org in orgs {
    let probe = go_oauth_probe_org(server, token.access_token, org)
    if !probe.ok {
      all_probes_ok = false
    }
    match probe.api {
      Some(api) => apis[org.id] = api
      None => ()
    }
  }
  let choice = match choose_go_org(orgs, token.org_id, apis, all_probes_ok) {
    Ok(choice) => choice
    Err(message) => raise @oauth.OAuthError::ParseError(message)
  }
  go_oauth_credential_from_login(
    token,
    go_trim_trailing_slash(server),
    org=choice.org,
    api_base=choice.api_base,
    email~,
    now_secs=go_now_secs(),
  )
}

///|
/// Exchange the refresh token; the Console rotates the pair, so persist the
/// result before using it.
pub async fn go_oauth_refresh(
  credential : @oauth.Credential,
) -> @oauth.Credential raise @oauth.OAuthError {
  let session = match go_oauth_session(credential) {
    Some(session) => session
    None =>
      raise @oauth.OAuthError::ParseError(
        "OpenCode Go OAuth credential is missing its access token",
      )
  }
  if session.refresh_token.length() == 0 {
    raise @oauth.OAuthError::InvalidGrant
  }
  let url = go_console_url(session.server, "/auth/device/token")
  let body : Json = Json::object(
    Map::from_array([
      ("grant_type", Json::string("refresh_token")),
      ("refresh_token", Json::string(session.refresh_token)),
      ("client_id", Json::string(go_console_client_id)),
    ]),
  )
  let (status, text) = go_console_post_json(url, body)
  let payload = go_parse_json_body(url, text)
  match parse_go_token_poll(status, payload) {
    Granted(token) =>
      go_oauth_refreshed_credential(credential, token, now_secs=go_now_secs())
    Failed(code) => raise go_poll_failed_error(code)
    Pending =>
      raise @oauth.OAuthError::HttpError(
        "OpenCode Console refresh is pending (status=\{status})",
      )
    SlowDown =>
      raise @oauth.OAuthError::HttpError(
        "OpenCode Console refresh was throttled (status=\{status})",
      )
  }
}
