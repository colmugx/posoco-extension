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
  { access_token, refresh_token, expires_at, token_type, metadata, }
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

///|
/// Read one provider-owned metadata value without exposing the map shape to a
/// host adapter.  Codex uses this accessor for its account id header.
pub fn Credential::metadata_value(self : Credential, key : String) -> String? {
  self.metadata.get(key)
}

///|
/// A provider-neutral stored API-key credential. The secret is opaque to the
/// host and is interpreted only by the provider extension that owns it.
pub(all) struct ApiKeyCredential {
  secret : String
  metadata : Map[String, String]
}

///|
pub fn ApiKeyCredential::ApiKeyCredential(
  secret~ : String,
  metadata? : Map[String, String] = Map([]),
) -> ApiKeyCredential {
  { secret, metadata, }
}

///|
/// The single active credential record for a provider.  A provider may expose
/// both OAuth and API-key login, but a host must persist exactly one selected
/// method under the provider's canonical id.  Keeping the method tag beside
/// the opaque payload prevents a host from silently preferring OAuth when both
/// legacy stores happen to contain a value.
pub(all) enum ProviderCredential {
  OAuth(Credential)
  ApiKey(ApiKeyCredential)
}

///|
/// Stable provider-neutral method id used by command payloads and storage
/// diagnostics.  This never includes credential material.
pub fn ProviderCredential::method_id(self : ProviderCredential) -> String {
  match self {
    OAuth(_) => "oauth"
    ApiKey(_) => "api_key"
  }
}

///|
/// Stable tagged persistence representation. The tag and payload live in one
/// record so a host cannot accidentally restore OAuth and API-key credentials
/// as two simultaneously active methods.
pub fn ProviderCredential::to_json(self : ProviderCredential) -> Json {
  match self {
    OAuth(credential) =>
      Json::object(
        Map([
          ("method", Json::string("oauth")),
          ("credential", credential.to_json()),
        ]),
      )
    ApiKey(credential) =>
      Json::object(
        Map([
          ("method", Json::string("api_key")),
          ("credential", credential.to_json()),
        ]),
      )
  }
}

///|
/// Decode the canonical tagged persistence shape. Provider-specific
/// validation remains in the provider extension; this only validates the
/// generic record envelope and opaque credential payload.
pub fn ProviderCredential::from_json(json : Json) -> ProviderCredential? {
  match json {
    Json::Object(map) => {
      let method_tag = match map.get("method") {
        Some(Json::String(value)) => value
        _ => return None
      }
      let payload = match map.get("credential") {
        Some(value) => value
        None => return None
      }
      match method_tag {
        "oauth" =>
          match Credential::from_json(payload) {
            Some(value) => Some(OAuth(value))
            None => None
          }
        "api_key" =>
          match ApiKeyCredential::from_json(payload) {
            Some(value) => Some(ApiKey(value))
            None => None
          }
        _ => None
      }
    }
    _ => None
  }
}

///|
/// Serialize without exposing provider-specific fields to the host.
pub fn ApiKeyCredential::to_json(self : ApiKeyCredential) -> Json {
  let meta_json : Map[String, Json] = Map([])
  for k, v in self.metadata {
    meta_json[k] = Json::string(v)
  }
  Json::object(
    Map([
      ("secret", Json::string(self.secret)),
      ("metadata", Json::object(meta_json)),
    ]),
  )
}

///|
/// Deserialize a generic API-key entry. Provider validation happens later in
/// its `ApiKeyFactory`; malformed generic shape is rejected here.
pub fn ApiKeyCredential::from_json(json : Json) -> ApiKeyCredential? {
  match json {
    Json::Object(map) => {
      let secret = match map.get("secret") {
        Some(Json::String(value)) =>
          if value.length() > 0 {
            value
          } else {
            return None
          }
        _ => return None
      }
      let metadata : Map[String, String] = Map([])
      match map.get("metadata") {
        Some(Json::Object(fields)) =>
          for key, value in fields {
            match value {
              Json::String(text) => metadata[key] = text
              _ => return None
            }
          }
        Some(_) => return None
        None => ()
      }
      Some(ApiKeyCredential::{ secret, metadata, })
    }
    _ => None
  }
}
