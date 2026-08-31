///|
/// Reply of one HTTP GET performed by an `HttpIo`. `body` is always valid
/// UTF-8 (3xx replies carry an empty body; the `location` header carries the
/// redirect target instead). `bytes_read` counts body bytes before decode.
/// `truncated` marks a body read that filled `max_bytes` without reaching EOF.
pub(all) struct HttpReply {
  status : Int
  reason : String
  content_type : String
  location : String?
  body : String
  bytes_read : Int
  truncated : Bool
}

///|
/// HTTP fetch seam for the webfetch tool. One GET, no redirect following,
/// body stream stops at `max_bytes`. Implementations must return a reply for
/// every HTTP status; only transport/decoding failures raise.
pub(open) trait HttpIo {
  async fn fetch(self : Self, url : String, max_bytes : Int) -> HttpReply raise @posoco.RuntimeError
}

///|
/// WebFetchTools — URL fetch tool provider.
///
/// Fetches an http/https URL, converts HTML to LLM-optimized markdown, and
/// returns a header block + body + continuation footer. Config knobs:
/// `timeout_ms` per fetch (redirect hops included), `max_chars` per page
/// returned to the model, `byte_cap` per raw download. `io` overrides the
/// default `@http` transport (tests/hosts inject fakes here). `cache`
/// memoizes converted documents per requested URL; the default cache runs
/// on a constant-zero clock, so its TTL never expires.
pub struct WebFetchTools {
  timeout_ms : Int
  max_chars : Int
  byte_cap : Int
  cache : DocCache
  io : &HttpIo?
}

///|
/// Canonical constructor. Use this everywhere to avoid cross-target naming drift.
pub fn WebFetchTools::WebFetchTools(
  timeout_ms? : Int = 30_000,
  max_chars? : Int = 50_000,
  byte_cap? : Int = 5_242_880,
  cache? : DocCache,
  io? : &HttpIo? = None,
) -> WebFetchTools {
  let cache : DocCache = match cache {
    Some(c) => c
    None => DocCache::DocCache()
  }
  { timeout_ms, max_chars, byte_cap, cache, io, }
}
