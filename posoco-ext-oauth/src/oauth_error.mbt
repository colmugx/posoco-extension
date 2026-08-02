///|
/// oauth_error.mbt — OAuth flow errors.

///|
pub(all) suberror OAuthError {
  AuthPending // device flow: user hasn't authorized yet
  SlowDown // device flow: poll too fast
  AccessDenied // user denied the request
  ExpiredToken // device code expired
  InvalidGrant // refresh token invalid/expired
  HttpError(String) // network or HTTP error
  ParseError(String) // response JSON parse failure
  Cancelled // user cancelled via AuthInteraction
} derive(Eq, Debug)

///|
impl Show for OAuthError with fn to_string(self) {
  match self {
    AuthPending => "OAuthError::AuthPending"
    SlowDown => "OAuthError::SlowDown"
    AccessDenied => "OAuthError::AccessDenied"
    ExpiredToken => "OAuthError::ExpiredToken"
    InvalidGrant => "OAuthError::InvalidGrant"
    HttpError(s) => "OAuthError::HttpError(\{s})"
    ParseError(s) => "OAuthError::ParseError(\{s})"
    Cancelled => "OAuthError::Cancelled"
  }
}
