///|
/// kimi_oauth.mbt — OAuth provider for Kimi (Moonshot) Code subscription.
///
/// Uses RFC 8628 device authorization grant (device code flow).
/// Kimi also supports API key auth (Bearer token); this OAuth impl is for
/// subscription reuse (Kimi Code Plan).

///|
/// Kimi OAuth endpoints (from kimi-code/kosong source).
let kimi_client_id : String = "17e5f671-d194-4dfb-9706-5516cb48c098"

///|
let kimi_oauth_host : String = "https://auth.kimi.com"

///|
let kimi_api_base : String = "https://api.kimi.com/coding"

///|
/// Kimi OAuth provider. Implements @oauth.OAuthProvider via device flow.
pub(all) struct KimiOAuth {
  // No state — endpoints are constants.
}

///|
pub fn KimiOAuth::KimiOAuth() -> KimiOAuth {
  KimiOAuth::{  }
}

///|
pub impl @oauth.OAuthProvider for KimiOAuth with fn provider_id(
  _self : KimiOAuth,
) -> String {
  "kimi"
}

///|
pub impl @oauth.OAuthProvider for KimiOAuth with fn login(
  _self : KimiOAuth,
  interaction : &@oauth.AuthInteraction,
) -> @oauth.Credential raise @oauth.OAuthError {
  let config : @oauth.DeviceFlowConfig = {
    client_id: kimi_client_id,
    device_auth_endpoint: kimi_oauth_host + "/api/oauth/device_authorization",
    token_endpoint: kimi_oauth_host + "/api/oauth/token",
    scope: "openid profile email offline_access",
  }
  @oauth.run_device_flow(config, interaction)
}

///|
pub impl @oauth.OAuthProvider for KimiOAuth with fn refresh(
  _self : KimiOAuth,
  credential : @oauth.Credential,
) -> @oauth.Credential raise @oauth.OAuthError {
  let headers : Map[String, String] = Map([
    ("Content-Type", "application/x-www-form-urlencoded"),
  ])
  let body = "client_id=" +
    kimi_client_id +
    "&grant_type=refresh_token&refresh_token=" +
    credential.refresh_token
  let (_, body_data) = @http.post(
    kimi_oauth_host + "/api/oauth/token",
    body,
    headers~,
  ) catch {
    err => raise @oauth.OAuthError::HttpError(err.to_string())
  }
  let body_text = body_data.text() catch {
    err =>
      raise @oauth.OAuthError::HttpError(
        "refresh body read: " + err.to_string(),
      )
  }
  let resp_json = @json.parse(body_text) catch {
    err =>
      raise @oauth.OAuthError::ParseError(
        "refresh response: " + err.to_string(),
      )
  }
  match resp_json {
    Json::Object(map) => {
      match map.get("error") {
        Some(Json::String(err_code)) => raise @oauth.OAuthError::InvalidGrant
        _ => ()
      }
      let access_token = match map.get("access_token") {
        Some(Json::String(s)) => s
        _ =>
          raise @oauth.OAuthError::ParseError(
            "missing access_token in refresh response",
          )
      }
      let refresh_token = match map.get("refresh_token") {
        Some(Json::String(s)) => s
        _ => credential.refresh_token
      }
      let expires_in = match map.get("expires_in") {
        Some(Json::Number(n, ..)) => n.to_int()
        _ => 3600
      }
      let token_type = match map.get("token_type") {
        Some(Json::String(s)) => s
        _ => "Bearer"
      }
      let now_secs = (@async.now() / 1000L).to_int()
      @oauth.Credential::Credential(
        access_token~,
        refresh_token~,
        expires_at=now_secs + expires_in,
        token_type~,
      )
    }
    _ =>
      raise @oauth.OAuthError::ParseError("refresh response is not an object")
  }
}

///|
pub impl @oauth.OAuthProvider for KimiOAuth with fn to_auth(
  _self : KimiOAuth,
  credential : @oauth.Credential,
) -> @oauth.AuthHeader {
  @oauth.AuthHeader::Bearer(credential.access_token)
}

///|
/// The API base URL for Kimi OAuth (subscription) mode.
/// When using OAuth, requests go to api.kimi.com/coding instead of
/// api.moonshot.ai/v1.
pub fn kimi_oauth_api_base() -> String {
  kimi_api_base
}
