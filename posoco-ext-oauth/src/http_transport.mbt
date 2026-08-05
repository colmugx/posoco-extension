///|
/// Provider-independent HTTP request seam used by OAuth flows.
///
/// The default implementation delegates to moonbitlang/async/http. Tests and
/// hosts may inject a fake transport to assert exact OAuth wire requests
/// without opening a network connection.

///|
pub(all) struct OAuthHttpRequest {
  url : String
  body : String
  headers : Map[String, String]
}

///|
pub fn OAuthHttpRequest::OAuthHttpRequest(
  url~ : String,
  body~ : String,
  headers~ : Map[String, String],
) -> OAuthHttpRequest {
  { url, body, headers }
}

///|
pub(all) struct OAuthHttpResponse {
  status : Int
  body : String
}

///|
pub fn OAuthHttpResponse::OAuthHttpResponse(
  status~ : Int,
  body~ : String,
) -> OAuthHttpResponse {
  { status, body }
}

///|
pub(open) trait OAuthHttpTransport {
  async fn post(Self, request : OAuthHttpRequest) -> OAuthHttpResponse raise OAuthError
}

///|
pub(all) struct DefaultOAuthHttpTransport {}

///|
pub fn DefaultOAuthHttpTransport::DefaultOAuthHttpTransport() -> DefaultOAuthHttpTransport {
  DefaultOAuthHttpTransport::{  }
}

///|
pub impl OAuthHttpTransport for DefaultOAuthHttpTransport with fn post(
  _self : DefaultOAuthHttpTransport,
  request : OAuthHttpRequest,
) -> OAuthHttpResponse raise OAuthError {
  // moonbitlang/async's timeout cancels the in-flight HTTP task.  Keep this
  // bound in the provider-independent transport so every OAuth endpoint gets
  // the same fail-fast deadline, including refresh calls.
  @async.with_timeout(30000, fn() {
    let (response, body_data) = @http.post(
      request.url,
      request.body,
      headers=request.headers,
    ) catch {
      err =>
        raise OAuthError::HttpError(
          "oauth HTTP POST failed: " + err.to_string(),
        )
    }
    let body = body_data.text() catch {
      err =>
        raise OAuthError::HttpError(
          "oauth HTTP response body read failed: " + err.to_string(),
        )
    }
    { status: response.code, body }
  }) catch {
    @async.TimeoutError =>
      raise OAuthError::HttpError(
        "oauth HTTP POST timed out (timeout_ms=30000)",
      )
    err =>
      raise OAuthError::HttpError("oauth HTTP POST failed: " + err.to_string())
  }
}

///|
/// Percent-encode one form value using the shared OAuth URL encoder. Providers
/// use this for client ids, device codes, and refresh tokens so secrets cannot
/// change the request shape when they contain reserved characters.
pub fn oauth_form_url_encode(value : String) -> String {
  url_encode(value)
}
