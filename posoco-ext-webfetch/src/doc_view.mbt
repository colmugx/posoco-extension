///|
/// One page of a converted document. `body` holds the characters at
/// [offset, end); `total` is the scalar-char count of the full text, so
/// `end < total` means truncation. `end` doubles as the next page's offset.
priv struct PageSlice {
  body : String
  offset : Int
  end : Int
  total : Int
  truncated : Bool
}

///|
/// Character-safe slicing: offsets and lengths count Unicode scalars (via
/// `for c in s`), so slicing never tears a surrogate pair. Returns None when
/// offset < 0 or offset >= total. Negative max_chars is treated as 0.
fn slice_chars(content : String, offset : Int, max_chars : Int) -> PageSlice? {
  if offset < 0 {
    return None
  }
  let mut total = 0
  for _ in content {
    total = total + 1
  }
  if offset >= total {
    return None
  }
  let budget = if max_chars < 0 { 0 } else { max_chars }
  let body = StringBuilder()
  let mut idx = 0
  let mut count = 0
  for ch in content {
    if count >= budget {
      break
    }
    if idx >= offset {
      body.write_char(ch)
      count = count + 1
    }
    idx = idx + 1
  }
  let end = offset + count
  Some(PageSlice::{
    body: body.to_string(),
    offset,
    end,
    total,
    truncated: end < total,
  })
}

///|
/// Model-visible success page: header block, blank line, body; a blank line
/// and a continuation footer are appended when the body was truncated.
fn format_page(
  title : String,
  url : String,
  content_type : String,
  slice : PageSlice,
) -> String {
  let head = "Title: \{title}\nURL: \{url}\nContent-Type: \{content_type}\n\n\{slice.body}"
  if slice.truncated {
    "\{head}\n\n… [showing characters \{slice.offset}–\{slice.end} of \{slice.total}; call webfetch with offset=\{slice.end} to continue]"
  } else {
    head
  }
}

///|
/// Cross-host redirect stop. This is a success outcome, not an error: the
/// model decides whether to trust the target and fetch it explicitly.
fn format_redirect(original : String, target : String) -> String {
  "Redirect: \{original} redirects to \{target} (different host; not followed automatically for safety). If you trust this target, call webfetch with url=\{target}."
}

///|
priv enum ErrKind {
  HttpError(status~ : Int, reason~ : String, url~ : String)
  TooLarge(bytes~ : Int, url~ : String)
  TimedOut(ms~ : Int, url~ : String)
  UnsupportedType(ct~ : String, url~ : String)
  HostBlocked(host~ : String)
  TooManyRedirects(hops~ : Int, url~ : String)
  Transport(msg~ : String, url~ : String)
  OffsetPastEnd(offset~ : Int, total~ : Int, url~ : String)
}

///|
/// Recovery advice bucket for an HTTP status. 404/403/5xx get specific hints;
/// every other status falls into the generic "check the URL" bucket.
fn http_advice(status : Int) -> String {
  if status == 404 {
    "the page may have moved; try the site index or a search"
  } else if status == 403 {
    "the site may block automated clients; try a different source"
  } else if status >= 500 && status <= 599 {
    "the server failed; retrying later may help"
  } else {
    "check the URL and parameters"
  }
}

///|
/// One-line, model-facing error text for every failure mode of a fetch.
fn format_error(kind : ErrKind) -> String {
  match kind {
    HttpError(status~, reason~, url~) =>
      "webfetch: HTTP \{status} \{reason} for '\{url}' — \{http_advice(status)}"
    TooLarge(bytes~, url~) =>
      "webfetch: response too large (\{bytes} bytes exceeds the 5 MB cap) for '\{url}'"
    TimedOut(ms~, url~) =>
      "webfetch: request to '\{url}' timed out after \{ms}ms — the site may be slow or blocking automated clients; retrying or using a different source may help"
    UnsupportedType(ct~, url~) =>
      "webfetch: unsupported content-type '\{ct}' for '\{url}' — this tool returns text, markdown, and JSON only"
    HostBlocked(host~) =>
      "webfetch: host '\{host}' is not allowed (private, local, or blocked address)"
    TooManyRedirects(hops~, url~) =>
      "webfetch: too many redirects (\{hops}) following '\{url}'"
    Transport(msg~, url~) => "webfetch: request to '\{url}' failed: \{msg}"
    OffsetPastEnd(offset~, total~, url~) =>
      "webfetch: offset \{offset} is past the end of the content (total \{total} characters) for '\{url}'"
  }
}

///|
/// Structured result channel for the host/UI. Field set and order are fixed.
fn structured_json(
  url_requested~ : String,
  url_final~ : String,
  status~ : Int,
  content_type~ : String,
  bytes_fetched~ : Int,
  chars_total~ : Int,
  chars_returned~ : Int,
  offset~ : Int,
  truncated~ : Bool,
  elapsed_ms~ : Int,
  cached~ : Bool,
) -> Json {
  Json::object(
    Map::from_array([
      ("url_requested", Json::string(url_requested)),
      ("url_final", Json::string(url_final)),
      ("status", Json::number(status.to_double())),
      ("content_type", Json::string(content_type)),
      ("bytes_fetched", Json::number(bytes_fetched.to_double())),
      ("chars_total", Json::number(chars_total.to_double())),
      ("chars_returned", Json::number(chars_returned.to_double())),
      ("offset", Json::number(offset.to_double())),
      ("truncated", Json::boolean(truncated)),
      ("elapsed_ms", Json::number(elapsed_ms.to_double())),
      ("cached", Json::boolean(cached)),
    ]),
  )
}
