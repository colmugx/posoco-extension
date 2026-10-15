///|
/// transport.mbt — the injectable gateway transport seam.
///
/// The manager never performs I/O itself: it speaks to the gateway through
/// this trait, so the whole control plane is testable against scripted
/// responses without a running Magpie. The default implementation is the
/// only place where `moonbitlang/async/http` is used.

///|
/// One HTTP GET against the gateway. Implementations raise
/// `MagpieGatewayError::Offline` for network-level failures (connection
/// refused, DNS, timeout) and return every HTTP status code as-is —
/// classification of statuses belongs to the refresh layer, which owns the
/// single pure classifier. Headers carry the request's freshly built
/// credential; implementations must not log headers or credentials.
pub(open) trait MagpieTransport {
  async fn get(Self, url : String, headers : Map[String, String]) -> (
    Int32,
    String,
  ) raise MagpieGatewayError
  async fn post(
    Self,
    url : String,
    headers~ : Map[String, String],
    body~ : String,
  ) -> (Int32, String) raise MagpieGatewayError
  async fn post_stream(
    Self,
    url : String,
    headers~ : Map[String, String],
    body~ : String,
  ) -> (Int32, &MagpieEventStream) raise MagpieGatewayError
}

///|
/// Outcome of one guarded HTTP attempt, carried as a value because
/// `with_timeout` takes a non-raising closure: the timeout is then the only
/// raised error and maps cleanly to `Offline`.
priv enum HttpOutcome {
  Answered(code~ : Int32, body~ : String)
  Failed(detail~ : String)
}

///|
/// Default transport over `moonbitlang/async/http`, applying the
/// configured connect timeout per request. Holds no state and no
/// credentials: headers arrive with each call.
pub struct HttpMagpieTransport {
  priv timeout_ms : Int32
}

///|
pub fn HttpMagpieTransport::HttpMagpieTransport(
  timeout_ms~ : Int32 = DEFAULT_CONNECT_TIMEOUT_MS,
) -> HttpMagpieTransport {
  { timeout_ms, }
}

///|
impl MagpieTransport for HttpMagpieTransport with fn get(
  self : HttpMagpieTransport,
  url : String,
  headers : Map[String, String],
) -> (Int32, String) raise MagpieGatewayError {
  let http_headers : @http.Headers = Map::from_array([])
  for key, value in headers {
    http_headers[@http.CaseInsensitiveString(key)] = value
  }
  let outcome = @async.with_timeout(self.timeout_ms, () => {
    let (response, body) = @http.get(url, headers=http_headers) catch {
      failure => return Failed(detail="request failed: \{failure}")
    }
    Answered(code=response.code, body=body.text())
  }) catch {
    failure =>
      raise MagpieGatewayError::Offline(
        "request timed out after \{self.timeout_ms}ms (\{failure})",
      )
  }
  match outcome {
    Answered(code~, body~) => (code, body)
    Failed(detail~) => raise MagpieGatewayError::Offline(detail)
  }
}

///|
/// An open streaming response body: lines of raw text until EOF. The
/// execution layer feeds the lines to the protocol kits' SSE decoders; the
/// transport never interprets them. `next_line` returns `None` at EOF and
/// is the stream's cancellation point. `close` is idempotent.
pub(open) trait MagpieEventStream {
  async fn next_line(Self) -> String? raise MagpieGatewayError
  async fn close_stream(Self) -> Unit raise MagpieGatewayError
}

///|
/// Buffered HTTP POST helper note: `post` returns the full body;
/// `post_stream` returns the status plus an open event stream whose lines
/// feed the protocol kits' SSE decoders. Both keep the `get` error
/// discipline: network failures raise `Offline`, statuses are returned
/// as-is, and credentials are never logged or stored.

///|
impl MagpieTransport for HttpMagpieTransport with fn post(
  self : HttpMagpieTransport,
  url : String,
  headers~ : Map[String, String],
  body~ : String,
) -> (Int32, String) raise MagpieGatewayError {
  let http_headers : @http.Headers = Map::from_array([])
  for key, value in headers {
    http_headers[@http.CaseInsensitiveString(key)] = value
  }
  let outcome = @async.with_timeout(self.timeout_ms, () => {
    let (response, data) = @http.post(url, body, headers=http_headers) catch {
      failure => return Failed(detail="request failed: \{failure}")
    }
    let text = data.text() catch {
      _ => return Failed(detail="response body could not be decoded")
    }
    Answered(code=response.code, body=text)
  }) catch {
    failure =>
      raise MagpieGatewayError::Offline(
        "request timed out after \{self.timeout_ms}ms (\{failure})",
      )
  }
  match outcome {
    Answered(code~, body~) => (code, body)
    Failed(detail~) => raise MagpieGatewayError::Offline(detail)
  }
}

///|
/// Streaming HTTP response over `moonbitlang/async/http`: one client per
/// request, `read_until("\n")` per line, closed exactly once on every exit
/// path by the caller-facing handle.
priv struct HttpEventStream {
  client : @http.Client
  mut closed : Bool
}

///|
impl MagpieEventStream for HttpEventStream with fn next_line(
  self : HttpEventStream,
) -> String? raise MagpieGatewayError {
  if self.closed {
    return None
  }
  self.client.read_until("\n") catch {
    err => raise MagpieGatewayError::Offline("stream read failed: \{err}")
  }
}

///|
impl MagpieEventStream for HttpEventStream with fn close_stream(
  self : HttpEventStream,
) -> Unit raise MagpieGatewayError {
  if !self.closed {
    self.closed = true
    self.client.close()
  }
}

///|
impl MagpieTransport for HttpMagpieTransport with fn post_stream(
  _self : HttpMagpieTransport,
  url : String,
  headers~ : Map[String, String],
  body~ : String,
) -> (Int32, &MagpieEventStream) raise MagpieGatewayError {
  let http_headers : @http.Headers = Map::from_array([])
  for key, value in headers {
    http_headers[@http.CaseInsensitiveString(key)] = value
  }
  let client = @http.post_stream(url, headers=http_headers) catch {
    err => raise MagpieGatewayError::Offline("stream open failed: \{err}")
  }
  client.write(body) catch {
    err => {
      client.close()
      raise MagpieGatewayError::Offline("stream write failed: \{err}")
    }
  }
  let response = client.end_request() catch {
    err => {
      client.close()
      raise MagpieGatewayError::Offline("stream start failed: \{err}")
    }
  }
  (response.code, HttpEventStream::{ client, closed: false, })
}
