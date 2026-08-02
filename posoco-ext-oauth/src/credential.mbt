///|
/// credential.mbt — OAuth credential types shared across all providers.

///|
/// A stored OAuth credential. All tokens are opaque strings to ext-oauth;
/// provider-specific fields (like OpenAI's account_id) go in `metadata`.
pub(all) struct Credential {
  access_token : String
  refresh_token : String
  expires_at : Int // epoch seconds; 0 = never expires
  token_type : String // usually "Bearer"
  metadata : Map[String, String]
}

///|
pub fn Credential::Credential(
  access_token~ : String,
  refresh_token~ : String,
  expires_at~ : Int,
  token_type? : String = "Bearer",
  metadata? : Map[String, String] = Map([]),
) -> Credential {
  { access_token, refresh_token, expires_at, token_type, metadata }
}

///|
/// Check if the access token is expired (with a 60-second safety margin).
pub fn Credential::is_expired(self : Credential, now_epoch : Int) -> Bool {
  if self.expires_at == 0 {
    false
  } else {
    now_epoch >= self.expires_at - 60
  }
}

///|
/// Serialize to JSON for persistence.
pub fn Credential::to_json(self : Credential) -> Json {
  let meta_json : Map[String, Json] = Map([])
  for k, v in self.metadata {
    meta_json[k] = Json::string(v)
  }
  Json::object(
    Map([
      ("access_token", Json::string(self.access_token)),
      ("refresh_token", Json::string(self.refresh_token)),
      ("expires_at", Json::number(self.expires_at.to_double())),
      ("token_type", Json::string(self.token_type)),
      ("metadata", Json::object(meta_json)),
    ]),
  )
}

///|
/// Deserialize from JSON. Returns None on parse failure.
pub fn Credential::from_json(json : Json) -> Credential? {
  match json {
    Json::Object(map) => {
      let access = match map.get("access_token") {
        Some(Json::String(s)) => s
        _ => return None
      }
      let refresh = match map.get("refresh_token") {
        Some(Json::String(s)) => s
        _ => return None
      }
      let expires = match map.get("expires_at") {
        Some(Json::Number(n, ..)) => n.to_int()
        _ => 0
      }
      let token_type = match map.get("token_type") {
        Some(Json::String(s)) => s
        _ => "Bearer"
      }
      let metadata : Map[String, String] = Map([])
      match map.get("metadata") {
        Some(Json::Object(meta_map)) =>
          for k, v in meta_map {
            match v {
              Json::String(s) => metadata[k] = s
              _ => ()
            }
          }
        _ => ()
      }
      Some(
        Credential::Credential(
          access_token=access,
          refresh_token=refresh,
          expires_at=expires,
          token_type~,
          metadata~,
        ),
      )
    }
    _ => None
  }
}

///|
/// How to apply the credential to an HTTP request.
pub(all) enum AuthHeader {
  Bearer(String) // Authorization: Bearer <token>
  Header(Map[String, String]) // custom headers
} derive(Eq, Debug)

///|
/// Build a Bearer auth header from a credential.
pub fn Credential::to_auth_header(self : Credential) -> AuthHeader {
  Bearer(self.access_token)
}
