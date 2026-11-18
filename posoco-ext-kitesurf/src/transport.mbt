///|
/// Raw HTTP response from the Browser Run REST endpoint. Cloudflare Quick
/// Actions return an ordinary JSON envelope even for successful requests.
pub(all) struct KitesurfHttpResponse {
  status : Int32
  body : String
}

///|
/// Inject this seam in tests; production uses DefaultKitesurfTransport.
/// Never log the headers: they contain the Bearer token.
pub(open) trait KitesurfHttpTransport {
  async fn post(
    Self,
    url : String,
    headers : Map[String, String],
    body : String,
  ) -> KitesurfHttpResponse raise @posoco.RuntimeError
}

///|
pub struct DefaultKitesurfTransport {}

///|
pub fn DefaultKitesurfTransport::DefaultKitesurfTransport() -> DefaultKitesurfTransport {
  DefaultKitesurfTransport::{ }
}

///|
/// Use the same MoonBit HTTP library as the existing oauth and webfetch
/// extensions. Error details are deliberately dropped to avoid reflecting
/// request headers, account secrets or user-controlled URLs.
pub impl KitesurfHttpTransport for DefaultKitesurfTransport with fn post(
  _self : DefaultKitesurfTransport,
  url : String,
  headers : Map[String, String],
  body : String,
) -> KitesurfHttpResponse raise @posoco.RuntimeError {
  let request_headers : @http.Headers = Map([])
  for key, value in headers {
    request_headers[key] = value
  }
  let (response, reply) = @http.post_text(
    url,
    body,
    headers=request_headers,
  ) catch {
    _ => raise @posoco.RuntimeError::InvocationFailed("kitesurf: HTTP transport failed")
  }
  let payload = reply.text() catch {
    _ => raise @posoco.RuntimeError::InvocationFailed("kitesurf: invalid HTTP response body")
  }
  { status: response.code, body: payload, }
}

///|
pub extend DefaultKitesurfTransport with KitesurfHttpTransport::{post}
