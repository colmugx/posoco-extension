///|
/// Response of one Nowledge Mem HTTP POST. `body` is the parsed JSON document;
/// a body that fails to decode or parse is reported as `Json::null()` so a
/// non-JSON error page still reaches the status-based predicates in acks.mbt
/// instead of failing the request outright.
pub(all) struct NmemResponse {
  status : Int
  body : Json
} derive(Debug)

///|
/// Narrow HTTP seam for Nowledge Mem thread sync (plan D7): one JSON POST with
/// a timeout, all failures normalized to `Err(String)`. Production sync uses
/// `HttpNmemTransport`; tests and hosts inject a scripted fake (M4).
pub(open) trait NmemTransport {
  async fn post_json(
    Self,
    url : String,
    headers : Map[String, String],
    body : Json,
    timeout_ms~ : Int,
  ) -> Result[NmemResponse, String]
}

///|
/// Default `NmemTransport` backed by `moonbitlang/async/http`. Its js backend
/// is fetch-based with the same API, so this implementation is shared by the
/// native and js targets (plan D1); no per-target split is needed.
pub(all) struct HttpNmemTransport {
  // empty
}

///|
pub fn HttpNmemTransport::HttpNmemTransport() -> HttpNmemTransport {
  HttpNmemTransport::{  }
}

///|
/// Headers every Nowledge Mem request carries: JSON content type, plus the
/// dual auth headers (`Authorization: Bearer` and `X-NMEM-API-Key`) when an
/// API key is configured (plan §1.3).
pub fn nmem_request_headers(config : NmemConfig) -> Map[String, String] {
  let headers : Map[String, String] = { "Content-Type": "application/json" }
  match config.api_key {
    Some(key) => {
      headers["Authorization"] = "Bearer " + key
      headers["X-NMEM-API-Key"] = key
    }
    None => ()
  }
  headers
}

///|
/// Inject the configured space as a top-level `space_id` when `body` is an
/// object without one (plan §1.3: `space` rides the request body, not the
/// URL). Returns a new Json with `space_id` appended after the existing
/// fields; non-object bodies, objects that already carry `space_id`, and a
/// `None` space pass through unchanged.
pub fn with_space_id(body : Json, space : String?) -> Json {
  match (space, body) {
    (Some(space), Json::Object(fields)) =>
      if fields.contains("space_id") {
        body
      } else {
        let merged : Map[String, Json] = Map([])
        for key, value in fields {
          merged[key] = value
        }
        merged["space_id"] = Json::string(space)
        Json::object(merged)
      }
    _ => body
  }
}

///|
/// Fallback origins for a `/remote-api`-prefixed remote base (plan §1.3,
/// upstream `remoteApiFallbackUrls`): an exact `/remote-api` path degrades to
/// the bare origin, a `/remote-api/...` path strips the prefix segment, and
/// anything else — including malformed URLs — yields no fallbacks.
pub fn remote_api_fallback_urls(url : String) -> Array[String] {
  match split_url(url) {
    Some((origin, path)) =>
      if path == "/remote-api" {
        [origin]
      } else if path.has_prefix("/remote-api/") {
        [origin + path["/remote-api".length():].to_owned()]
      } else {
        []
      }
    None => []
  }
}

///|
/// Split `scheme://host[:port]/path...` into the origin accepted by
/// `@http.Client::Client` (which rejects URIs whose path is not "/") and the
/// request path (defaulting to "/"). The query string stays with the path.
/// Returns `None` for URLs without an http/https scheme, an empty host, or a
/// malformed port.
fn split_url(url : String) -> (String, String)? {
  let scheme_len = if url.has_prefix("https://") {
    "https://".length()
  } else if url.has_prefix("http://") {
    "http://".length()
  } else {
    return None
  }
  let rest = url[scheme_len:]
  let authority_len = match rest.find("/") {
    Some(i) => i
    None => rest.length()
  }
  guard authority_valid(rest[:authority_len]) else { return None }
  let origin = url[:scheme_len + authority_len].to_owned()
  let path = if authority_len == rest.length() {
    "/"
  } else {
    rest[authority_len:].to_owned()
  }
  Some((origin, path))
}

///|
/// An authority is valid when its host is non-empty and, when a port is
/// present, the port is non-empty digits. Bracketed IPv6 hosts contain colons
/// themselves, so the port check only runs after the closing bracket.
fn authority_valid(authority : StringView) -> Bool {
  let host_and_port : (StringView, StringView?) = if authority.has_prefix("[") {
    match authority.find("]") {
      Some(end) => {
        let host = authority[:end + 1]
        let tail = authority[end + 1:]
        if tail.length() == 0 {
          (host, None)
        } else if tail.has_prefix(":") {
          (host, Some(tail[1:]))
        } else {
          return false
        }
      }
      None => return false
    }
  } else {
    match authority.find(":") {
      Some(i) => (authority[:i], Some(authority[i + 1:]))
      None => (authority, None)
    }
  }
  let (host, port) = host_and_port
  if host.length() == 0 {
    return false
  }
  match port {
    Some(port) => port.length() > 0 && port.all(fn(c) { c is ('0'..='9') })
    None => true
  }
}

///|
/// Shared implementation of `NmemTransport::post_json`. Follows the
/// posoco-ext-openai client lifecycle (`Client::Client` → `request` →
/// `write` → `flush` → `end_request` → `read_all`) with `close()` on every
/// exit path. The URL is split because `Client::Client` only accepts a
/// pathless origin; the request path is passed to `request`.
pub impl NmemTransport for HttpNmemTransport with fn post_json(
  _self : HttpNmemTransport,
  url : String,
  headers : Map[String, String],
  body : Json,
  timeout_ms~ : Int,
) -> Result[NmemResponse, String] {
  guard split_url(url) is Some((origin, path)) else {
    return Err("nmem transport failure (stage=split_url): invalid url: " + url)
  }
  // @http headers are case-insensitively keyed; the trait contract keeps
  // plain String keys and converts at this single @http boundary.
  let http_headers : @http.Headers = Map([])
  for key, value in headers {
    http_headers[key] = value
  }
  // The timeout bounds the whole exchange; on timeout the in-flight task is
  // cancelled, so a connection caught mid-await may skip close().
  let outcome : Result[NmemResponse, String] = @async.with_timeout(timeout_ms, () => {
    let client = @http.Client::Client(origin, headers=http_headers) catch {
      err =>
        return Err(
          "nmem transport failure (stage=create_client): " + err.to_string(),
        )
    }
    client.request(@http.RequestMethod::Post, path) catch {
      err => {
        client.close()
        return Err(
          "nmem transport failure (stage=send_request): " + err.to_string(),
        )
      }
    }
    client.write(body.stringify()) catch {
      err => {
        client.close()
        return Err(
          "nmem transport failure (stage=write_body): " + err.to_string(),
        )
      }
    }
    client.flush() catch {
      err => {
        client.close()
        return Err("nmem transport failure (stage=flush): " + err.to_string())
      }
    }
    let response = client.end_request() catch {
      err => {
        client.close()
        return Err(
          "nmem transport failure (stage=end_request): " + err.to_string(),
        )
      }
    }
    let body_data = client.read_all() catch {
      err => {
        client.close()
        return Err(
          "nmem transport failure (stage=read_response): " + err.to_string(),
        )
      }
    }
    client.close()
    let body_json = @json.parse(body_data.text()) catch { _ => Json::null() }
    Ok({ status: response.code, body: body_json })
  }) catch {
    @async.TimeoutError =>
      Err(
        "nmem transport failure (stage=timeout, timeout_ms=" +
        timeout_ms.to_string() +
        ")",
      )
    err => Err("nmem transport failure: " + err.to_string())
  }
  outcome
}
