///|
/// Provider-independent HTTP request seam used by OAuth flows.
///
/// The trait is defined here (compiled on every target) together with the
/// `DefaultOAuthHttpTransport` impls that delegate to `moonbitlang/async/http`
/// (native+js only). On wasm/wasm-gc the trait is still available for a host
/// to implement; there is simply no default transport. Tests and hosts may
/// also inject a fake transport to assert exact OAuth wire requests without a
/// network connection.

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
  { url, body, headers, }
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
  { status, body, }
}

///|
/// HTTP POST seam. `DefaultOAuthHttpTransport` provides a native+js impl that
/// calls `moonbitlang/async/http`; wasm/wasm-gc has no default (hosts supply
/// their own transport or OAuth HTTP flows are unavailable on that target).
pub(open) trait OAuthHttpTransport {
  async fn post(Self, request : OAuthHttpRequest) -> OAuthHttpResponse raise OAuthError

  /// GET seam for metadata discovery (RFC 9728 / RFC 8414). The default is
  /// fail-closed so existing post-only impls keep compiling; transports that
  /// can GET must override it.
  async fn get(Self, url : String, headers : Map[String, String]) -> OAuthHttpResponse raise OAuthError = _
}

///|
impl OAuthHttpTransport with fn get(_self, _url, _headers) -> OAuthHttpResponse raise OAuthError {
  raise OAuthError::HttpError("GET not supported by this transport")
}

///|
/// Marker struct for the default `@http`-backed transport. Constructed on any
/// target; its `OAuthHttpTransport` impl is compiled only on native+js.
pub(all) struct DefaultOAuthHttpTransport {
  // empty
}

///|
pub fn DefaultOAuthHttpTransport::DefaultOAuthHttpTransport() -> DefaultOAuthHttpTransport {
  DefaultOAuthHttpTransport::{ }
}

///|
/// Percent-encode one form value using the shared OAuth URL encoder. Providers
/// use this for client ids, device codes, and refresh tokens so secrets cannot
/// change the request shape when they contain reserved characters.
pub fn oauth_form_url_encode(value : String) -> String {
  url_encode(value)
}

///|
pub impl OAuthHttpTransport for DefaultOAuthHttpTransport with fn post(
  _self : DefaultOAuthHttpTransport,
  request : OAuthHttpRequest,
) -> OAuthHttpResponse raise OAuthError {
  // moonbitlang/async's timeout cancels the in-flight HTTP task.  Keep this
  // bound in the provider-independent transport so every OAuth endpoint gets
  // the same fail-fast deadline, including refresh calls.
  @async.with_timeout(30000, () => {
    // async 0.21: @http headers are case-insensitively keyed. The
    // transport-agnostic contract stays Map[String, String] (fakes and
    // providers keep plain keys) and converts at this single @http boundary.
    let http_headers : @http.Headers = Map([])
    for k, v in request.headers {
      http_headers[k] = v
    }
    let (response, body_data) = @http.post(
      request.url,
      request.body,
      headers=http_headers,
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
    { status: response.code, body, }
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
pub impl OAuthHttpTransport for DefaultOAuthHttpTransport with fn get(
  _self : DefaultOAuthHttpTransport,
  url : String,
  headers : Map[String, String],
) -> OAuthHttpResponse raise OAuthError {
  @async.with_timeout(30000, () => {
    let http_headers : @http.Headers = Map([])
    for k, v in headers {
      http_headers[k] = v
    }
    let (response, body_data) = @http.get(url, headers=http_headers) catch {
      err =>
        raise OAuthError::HttpError("oauth HTTP GET failed: " + err.to_string())
    }
    let body = body_data.text() catch {
      err =>
        raise OAuthError::HttpError(
          "oauth HTTP response body read failed: " + err.to_string(),
        )
    }
    { status: response.code, body, }
  }) catch {
    @async.TimeoutError =>
      raise OAuthError::HttpError("oauth HTTP GET timed out (timeout_ms=30000)")
    err =>
      raise OAuthError::HttpError("oauth HTTP GET failed: " + err.to_string())
  }
}
