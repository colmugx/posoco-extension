// WebFetchTools' ToolProvider: the `webfetch` tool pipeline. Pinned to
// [native, js] because it touches `default_http_io` (moonbitlang/async/http
// has no network stack on wasm) and `@async.now`; wasm gets the inert impl
// in wasm_fallback.mbt.

///|
/// Extract and validate `(url, offset?)` from ToolCall arguments. Typed
/// UnknownTool errors for every malformed shape so the model can retry with
/// corrected arguments.
fn extract_fetch_args(
  args : Json,
) -> (ParsedUrl, Int?) raise @posoco.RuntimeError {
  match args {
    Object(obj) => {
      let url = match obj.get("url") {
        Some(String(u)) => u
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "webfetch: 'url' argument must be a string",
          )
        None =>
          raise @posoco.RuntimeError::UnknownTool("webfetch: missing 'url'")
      }
      let offset = match obj.get("offset") {
        Some(Number(n, ..)) => {
          let v = n.to_int()
          if v < 0 {
            raise @posoco.RuntimeError::UnknownTool(
              "webfetch: 'offset' must be a non-negative integer",
            )
          }
          Some(v)
        }
        Some(Null) | None => None
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "webfetch: optional 'offset' must be an integer",
          )
      }
      if !url_length_ok(url) {
        raise @posoco.RuntimeError::UnknownTool(
          "webfetch: 'url' exceeds the 2000 character limit",
        )
      }
      guard parse_url(url) is Some(parsed) else {
        raise @posoco.RuntimeError::UnknownTool(
          "webfetch: 'url' must be an absolute http/https URL",
        )
      }
      (parsed, offset)
    }
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "webfetch: arguments must be a JSON object",
      )
  }
}

///|
/// Outcome of the redirect-following fetch loop: a final document reply, or
/// a cross-host redirect stop (a success the model decides on).
priv enum FetchLoop {
  Document(page~ : ParsedUrl, reply~ : HttpReply)
  RedirectStop(target~ : String)
}

///|
/// Fetch `requested` following same-origin redirects (at most 5 hops). Every
/// hop's host is re-guarded, and a blocked redirect target is refused before
/// any request is made. Transport and decoding failures raise; HTTP-level
/// failures come back as ErrKind for the caller to format.
async fn follow_redirects(
  io : &HttpIo,
  byte_cap : Int,
  requested : ParsedUrl,
) -> Result[FetchLoop, ErrKind] raise @posoco.RuntimeError {
  let req_url = requested.to_url_string()
  let mut current = requested
  let mut hops = 0
  while true {
    match check_host(current) {
      HostBlocked(_) =>
        return Err(ErrKind::HostBlocked(host=current.host_display()))
      HostAllowed => ()
    }
    let reply = io.fetch(current.to_url_string(), byte_cap)
    if reply.status >= 300 && reply.status < 400 {
      match reply.location {
        Some(loc) => {
          let target = current.join(loc)
          match check_host(target) {
            HostBlocked(_) =>
              return Err(ErrKind::HostBlocked(host=target.host_display()))
            HostAllowed => ()
          }
          if same_origin(current, target) {
            hops = hops + 1
            if hops > 5 {
              return Err(ErrKind::TooManyRedirects(hops=5, url=req_url))
            }
            current = target
            continue
          }
          return Ok(RedirectStop(target=target.to_url_string()))
        }
        None =>
          return Err(
            ErrKind::Transport(
              msg="redirect without Location header",
              url=current.to_url_string(),
            ),
          )
      }
    }
    if reply.status >= 400 {
      return Err(
        ErrKind::HttpError(
          status=reply.status,
          reason=reply.reason,
          url=current.to_url_string(),
        ),
      )
    }
    return Ok(Document(page=current, reply~))
  } nobreak {
    raise @posoco.RuntimeError::InvocationFailed(
      "webfetch: redirect loop exited unexpectedly",
    )
  }
}

///|
/// Content-type dispatch for a fetched body. Returns (title, content):
/// HTML is converted to markdown (links absolutized against the final URL);
/// markdown, plain text, and JSON (incl. `+json` subtypes) pass through
/// unchanged with a title from the final URL's last path segment. None
/// marks an unsupported type.
fn dispatch_content_type(
  ct : String,
  body : String,
  final_url : String,
) -> (String, String)? {
  let base : String = match ct.find(";") {
    Some(i) => ct[:i].to_owned().trim().to_owned().to_lower()
    None => ct.trim().to_owned().to_lower()
  }
  if base == "text/html" {
    let doc = html_to_markdown(body, base=final_url)
    return Some((doc.title, doc.markdown))
  }
  if base == "text/markdown" ||
    base == "text/plain" ||
    base == "application/json" ||
    base.has_suffix("+json") {
    return Some((url_title(final_url), body))
  }
  None
}

///|
/// Fallback title for pass-through content: the final URL's last path
/// segment, or the host when the path ends in '/'.
fn url_title(final_url : String) -> String {
  let u : String = match final_url.find("?") {
    Some(i) => final_url[:i].to_owned()
    None => final_url
  }
  let start : Int = match u.find("://") {
    Some(i) => i + 3
    None => 0
  }
  let mut cut = -1
  for i in start..<u.length() {
    if u[i] == 47 {
      cut = i
    }
  }
  if cut >= 0 {
    let seg : String = u[cut + 1:].to_owned()
    if seg.length() > 0 {
      return seg
    }
  }
  // No path segment: fall back to the host (up to '/', ':' or end).
  let mut end = u.length()
  for i in start..<u.length() {
    let ch : UInt16 = u[i]
    if ch == 47 || ch == 58 {
      // '/', ':'
      end = i
      break
    }
  }
  u[start:end].to_owned()
}

///|
/// Scalar-char count (same counting rule as slice_chars' totals).
fn count_chars(s : String) -> Int {
  let mut n = 0
  for _ in s {
    n = n + 1
  }
  n
}

///|
/// Wrap a model-facing error kind into the ToolReportedError outcome.
fn reported_error(kind : ErrKind) -> @posoco.ToolOutcome {
  @posoco.ToolOutcome::ToolReportedError(
    content=format_error(kind),
    structured=None,
  )
}

///|
/// Serve a page from the cache: slice, format, and report `cached=true`.
fn serve_cached(
  doc : CachedDoc,
  req_url : String,
  offset : Int,
  max_chars : Int,
) -> @posoco.ToolOutcome {
  match slice_chars(doc.content, offset, max_chars) {
    None =>
      reported_error(
        ErrKind::OffsetPastEnd(
          offset~,
          total=count_chars(doc.content),
          url=req_url,
        ),
      )
    Some(slice) =>
      @posoco.ToolOutcome::Success(
        content=format_page(doc.title, doc.url_final, doc.content_type, slice),
        structured=Some(
          structured_json(
            url_requested=req_url,
            url_final=doc.url_final,
            status=doc.status,
            content_type=doc.content_type,
            bytes_fetched=doc.bytes_fetched,
            chars_total=slice.total,
            chars_returned=slice.end - slice.offset,
            offset=slice.offset,
            truncated=slice.truncated,
            elapsed_ms=0,
            cached=true,
          ),
        ),
      )
  }
}

///|
pub impl @posoco.ToolProvider for WebFetchTools with fn list_tools(
  _self : WebFetchTools,
) -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("webfetch"),
      description: "Fetch content from an http/https URL and return it as LLM-optimized markdown with a Title/URL/Content-Type header block. HTML pages are converted to markdown (links absolutized, boilerplate dropped); text, markdown, and JSON responses pass through unchanged. Optional `offset` continues a truncated result at the given character offset (see the footer of a truncated response). Cross-host redirects are not followed: the result names the redirect target to re-fetch. Private and local addresses are blocked. Caps: 5 MB fetch, 50000 characters per call.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "url": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Absolute http/https URL to fetch"),
          }),
          "offset": Json::object({
            "type": Json::string("integer"),
            "description": Json::string(
              "Character offset to continue a truncated result from (see the footer of a truncated response)",
            ),
          }),
        }),
        "required": Json::array([Json::string("url")]),
      }),
      owner: @posoco.OwnerId::unchecked("posoco_ext_webfetch"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some("posoco_ext_webfetch"),
    },
  ]
}

///|
pub impl @posoco.ToolProvider for WebFetchTools with fn execute(
  self : WebFetchTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let (parsed, offset) = extract_fetch_args(call.arguments)
  let req_url = parsed.to_url_string()
  let offset0 = match offset {
    Some(o) => o
    None => 0
  }
  // Cache hit: serve the stored conversion without touching the network.
  match self.cache.get(req_url) {
    Some(doc) => return serve_cached(doc, req_url, offset0, self.max_chars)
    None => ()
  }
  let io : &HttpIo = match self.io {
    Some(io) => io
    None => default_http_io()
  }
  let started = @async.now()
  let fetched : Result[FetchLoop, ErrKind] = @async.with_timeout(
    self.timeout_ms,
    () => follow_redirects(io, self.byte_cap, parsed),
  ) catch {
    @async.TimeoutError =>
      return reported_error(ErrKind::TimedOut(ms=self.timeout_ms, url=req_url))
    err =>
      return reported_error(
        ErrKind::Transport(msg=err.to_string(), url=req_url),
      )
  }
  let elapsed_ms = (@async.now() - started).to_int()
  let loop_result = match fetched {
    Ok(v) => v
    Err(kind) => return reported_error(kind)
  }
  match loop_result {
    RedirectStop(target~) =>
      return @posoco.ToolOutcome::Success(
        content=format_redirect(req_url, target),
        structured=Some(
          Json::object(
            Map::from_array([
              ("url_requested", Json::string(req_url)),
              ("redirect_to", Json::string(target)),
              ("elapsed_ms", Json::number(elapsed_ms.to_double())),
            ]),
          ),
        ),
      )
    Document(page~, reply~) => {
      let final_url = page.to_url_string()
      if reply.truncated {
        return reported_error(
          ErrKind::TooLarge(bytes=reply.bytes_read, url=final_url),
        )
      }
      match dispatch_content_type(reply.content_type, reply.body, final_url) {
        None =>
          return reported_error(
            ErrKind::UnsupportedType(ct=reply.content_type, url=final_url),
          )
        Some((title, content)) => {
          self.cache.put(req_url, CachedDoc::{
            title,
            content,
            content_type: reply.content_type,
            url_requested: req_url,
            url_final: final_url,
            status: reply.status,
            bytes_fetched: reply.bytes_read,
            retrieved_ms: @async.now(),
          })
          match slice_chars(content, offset0, self.max_chars) {
            None =>
              return reported_error(
                ErrKind::OffsetPastEnd(
                  offset=offset0,
                  total=count_chars(content),
                  url=req_url,
                ),
              )
            Some(slice) =>
              return @posoco.ToolOutcome::Success(
                content=format_page(title, final_url, reply.content_type, slice),
                structured=Some(
                  structured_json(
                    url_requested=req_url,
                    url_final=final_url,
                    status=reply.status,
                    content_type=reply.content_type,
                    bytes_fetched=reply.bytes_read,
                    chars_total=slice.total,
                    chars_returned=slice.end - slice.offset,
                    offset=slice.offset,
                    truncated=slice.truncated,
                    elapsed_ms~,
                    cached=false,
                  ),
                ),
              )
          }
        }
      }
    }
  }
}

///|
/// Compose a ready-to-use WebFetchTools: real `@async.now()` clock in the
/// document cache and the default `@http` transport. Hosts that need custom
/// transports or clocks should construct WebFetchTools directly.
pub fn webfetch_extension() -> WebFetchTools {
  WebFetchTools::WebFetchTools(
    cache=DocCache::DocCache(now_ms=fn() { @async.now() }),
    io=Some(default_http_io()),
  )
}
