// Default HttpIo transport backed by moonbitlang/async/http.
// Target-gated to [native, js] via moon.pkg: moonbitlang/async has no network
// stack on wasm targets, so hosts there inject their own `HttpIo`.

///|
/// Marker struct for the `@http`-backed transport; compiled only on native+js.
priv struct DefaultHttpIo {}

///|
/// Canonical `@http` transport for `HttpIo`. Unused until the pipeline wires
/// it (transient).
pub fn default_http_io() -> &HttpIo {
  DefaultHttpIo::{ } as &HttpIo
}

///|
/// Stream up to `max_bytes` body bytes, close the client on every path (an
/// unclosed socket hangs the js process), then decode UTF-8. Short reads are
/// normal; a 0 return is EOF. The third tuple element is the truncated flag:
/// true only when the read filled `max_bytes` without ever seeing EOF (a body
/// of exactly `max_bytes` is indistinguishable from an over-long one without
/// an extra probe read, so it is also reported as truncated).
async fn read_response_body(
  client : @http.Client,
  max_bytes : Int,
) -> (String, Int, Bool) raise @posoco.RuntimeError {
  let buf : FixedArray[Byte] = FixedArray::make(max_bytes, b'\x00')
  let mut total = 0
  let mut saw_eof = false
  while total < max_bytes {
    let n = client.read(buf, offset=total, max_len=max_bytes - total) catch {
      err => {
        client.close()
        raise @posoco.RuntimeError::InvocationFailed(
          "webfetch: request failed: " + err.to_string(),
        )
      }
    }
    if n == 0 {
      saw_eof = true
      break
    }
    total = total + n
  }
  client.close()
  let raw = Bytes::makei(total, i => buf[i])
  let body = @utf8.decode(raw.view()) catch {
    _ =>
      raise @posoco.RuntimeError::InvocationFailed(
        "webfetch: response body is not valid UTF-8",
      )
  }
  (body, total, total == max_bytes && !saw_eof)
}

///|
impl HttpIo for DefaultHttpIo with fn fetch(
  _self : DefaultHttpIo,
  url : String,
  max_bytes : Int,
) -> HttpReply raise @posoco.RuntimeError {
  let headers : @http.Headers = Map::from_array([
    (
      @http.CaseInsensitiveString("accept"),
      "text/markdown;q=1.0, text/plain;q=0.9, application/json;q=0.9, text/html;q=0.8, */*;q=0.1",
    ),
    (@http.CaseInsensitiveString("accept-encoding"), "gzip"),
    (
      @http.CaseInsensitiveString("user-agent"),
      "posoco-webfetch/0.1 (+https://github.com/colmugx/posoco)",
    ),
  ])
  let (response, client) = @http.get_stream(url, headers~) catch {
    err =>
      raise @posoco.RuntimeError::InvocationFailed(
        "webfetch: request failed: " + err.to_string(),
      )
  }
  let status = response.code
  let content_type = match
    response.headers.get(@http.CaseInsensitiveString("content-type")) {
    Some(ct) => ct
    None => ""
  }
  let location = response.headers.get(@http.CaseInsensitiveString("location"))
  // 3xx: only the redirect target matters, so skip the body. Every other
  // status streams: 4xx/5xx error pages are often HTML and the pipeline
  // dispatches on content_type.
  let (body, bytes_read, truncated) = if status < 300 || status >= 400 {
    read_response_body(client, max_bytes)
  } else {
    client.close()
    ("", 0, false)
  }
  {
    status,
    reason: response.reason,
    content_type,
    location,
    body,
    bytes_read,
    truncated,
  }
}
