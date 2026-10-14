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
