///|

///|
/// Kimi OAuth endpoints (from kimi-code/kosong source).
let kimi_client_id : String = "17e5f671-d194-4dfb-9706-5516cb48c098"

///|
let kimi_oauth_host : String = "https://auth.kimi.com"

///|
let kimi_api_base : String = "https://api.kimi.com/coding/v1"

///|
/// RFC 8628 device-flow OAuth for the Kimi Code subscription.
pub(all) struct KimiOAuth {
  transport : &@oauth.OAuthHttpTransport?
  /// Sent as `X-Msh-Device-Id`; empty = fresh process-local UUID.
  device_id : String?
  /// Canned host identity (tests); None probes the real machine.
  identity : KimiIdentity?
}

///|
pub fn KimiOAuth::KimiOAuth(
  transport? : &@oauth.OAuthHttpTransport? = None,
  device_id? : String = "",
  identity? : KimiIdentity? = None,
) -> KimiOAuth {
  {
    transport,
    device_id: if device_id.length() > 0 {
      Some(device_id)
    } else {
      None
    },
    identity,
  }
}

///|
pub impl @oauth.OAuthProvider for KimiOAuth with fn provider_id(
  _self : KimiOAuth,
) -> String {
  "kimi"
}

///|
pub impl @oauth.OAuthProvider for KimiOAuth with fn login(
  self : KimiOAuth,
  interaction : &@oauth.AuthInteraction,
) -> @oauth.Credential raise @oauth.OAuthError {
  let identity_headers = match self.device_id {
    Some(id) => kimi_default_headers(device_id=id, identity=self.identity)
    None => kimi_default_headers(identity=self.identity)
  }
  let config : @oauth.DeviceFlowConfig = {
    client_id: kimi_client_id,
    device_auth_endpoint: kimi_oauth_host + "/api/oauth/device_authorization",
    token_endpoint: kimi_oauth_host + "/api/oauth/token",
    scope: "openid profile email offline_access",
    default_headers: identity_headers,
  }
  match self.transport {
    Some(transport) =>
      @oauth.run_device_flow_with_transport(config, interaction, transport)
    None => @oauth.run_device_flow(config, interaction)
  }
}

///|
pub impl @oauth.OAuthProvider for KimiOAuth with fn refresh(
  self : KimiOAuth,
  credential : @oauth.Credential,
) -> @oauth.Credential raise @oauth.OAuthError {
  let identity_headers = match self.device_id {
    Some(id) => kimi_default_headers(device_id=id, identity=self.identity)
    None => kimi_default_headers(identity=self.identity)
  }
  let headers : Map[String, String] = Map::from_array([])
  for k, v in identity_headers {
    headers[k] = v
  }
  headers["Content-Type"] = "application/x-www-form-urlencoded"
  headers["Accept"] = "application/json"
  let body = "client_id=" +
    @oauth.oauth_form_url_encode(kimi_client_id) +
    "&grant_type=refresh_token&refresh_token=" +
    @oauth.oauth_form_url_encode(credential.refresh_token)
  let default_transport = @oauth.DefaultOAuthHttpTransport::DefaultOAuthHttpTransport()
  let transport : &@oauth.OAuthHttpTransport = match self.transport {
    Some(value) => value
    None => default_transport
  }
  // Kimi intermittently 429/5xxs during refresh; other statuses are terminal.
  let mut retry = 0
  while true {
    let response = transport.post(@oauth.OAuthHttpRequest::{
      url: kimi_oauth_host + "/api/oauth/token",
      body,
      headers,
    })
    if response.status == 429 || response.status >= 500 {
      if retry < 3 {
        let delay_ms = match retry {
          0 => 1000
          1 => 2000
          _ => 4000
        }
        @async.sleep(delay_ms) catch {
          err =>
            raise @oauth.OAuthError::HttpError(
              "refresh retry sleep failed: " + err.to_string(),
            )
        }
        retry += 1
        continue
      }
      raise @oauth.OAuthError::HttpError(
        "refresh HTTP status=" +
        response.status.to_string() +
        ", body_chars=" +
        response.body.length().to_string() +
        ", retries=3",
      )
    }
    let resp_json = @json.parse(response.body) catch {
      err =>
        raise @oauth.OAuthError::ParseError(
          "refresh response: " + err.to_string(),
        )
    }
    match resp_json {
      Json::Object(map) => {
        match map.get("error") {
          Some(Json::String(err_code)) =>
            match err_code {
              "invalid_grant" => raise @oauth.OAuthError::InvalidGrant
              other =>
                raise @oauth.OAuthError::HttpError(
                  "refresh error=" +
                  other +
                  ", status=" +
                  response.status.to_string(),
                )
            }
          _ => ()
        }
        if response.status < 200 || response.status >= 300 {
          raise @oauth.OAuthError::HttpError(
            "refresh HTTP status=" +
            response.status.to_string() +
            ", body_chars=" +
            response.body.length().to_string(),
          )
        }
        let access_token = match map.get("access_token") {
          Some(Json::String(s)) =>
            if s.length() > 0 {
              s
            } else {
              raise @oauth.OAuthError::ParseError(
                "missing access_token in refresh response",
              )
            }
          _ =>
            raise @oauth.OAuthError::ParseError(
              "missing access_token in refresh response",
            )
        }
        let refresh_token = match map.get("refresh_token") {
          Some(Json::String(s)) =>
            if s.length() > 0 {
              s
            } else {
              raise @oauth.OAuthError::ParseError(
                "missing refresh_token in refresh response",
              )
            }
          _ =>
            raise @oauth.OAuthError::ParseError(
              "missing refresh_token in refresh response",
            )
        }
        let expires_in = match map.get("expires_in") {
          Some(Json::Number(n, ..)) =>
            match parse_kimi_positive_integer(n) {
              Some(value) => value
              None =>
                raise @oauth.OAuthError::ParseError(
                  "invalid expires_in in refresh response",
                )
            }
          _ =>
            raise @oauth.OAuthError::ParseError(
              "missing expires_in in refresh response",
            )
        }
        let token_type = match map.get("token_type") {
          Some(Json::String(s)) => if s.length() > 0 { s } else { "Bearer" }
          _ => "Bearer"
        }
        let now_secs = (@async.now() / 1000L).to_int()
        return @oauth.Credential::Credential(
          access_token~,
          refresh_token~,
          expires_at=now_secs + expires_in,
          token_type~,
        )
      }
      _ =>
        raise @oauth.OAuthError::ParseError("refresh response is not an object")
    }
  } nobreak {
    raise @oauth.OAuthError::HttpError("refresh loop terminated unexpectedly")
  }
}

///|
/// Token lifetimes must be finite positive integers; fractional values are
/// rejected.
fn parse_kimi_positive_integer(value : Double) -> Int? {
  if value.is_nan() || value.is_inf() || value <= 0.0 {
    return None
  }
  let integer = value.to_int()
  if integer <= 0 || value != integer.to_double() {
    None
  } else {
    Some(integer)
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
pub fn kimi_oauth_api_base() -> String {
  kimi_api_base
}
