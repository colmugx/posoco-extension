///|
test "wf skeleton" {
  let tools = WebFetchTools::WebFetchTools()
  inspect(tools.timeout_ms, content="30000")
}

///|
/// ——— Test helpers ———

///|
priv struct FakeHttpIo {
  replies : Array[HttpReply]
  urls : Array[String]
  mut calls : Int
  delay_ms : Int
}

///|
impl HttpIo for FakeHttpIo with fn fetch(
  self : FakeHttpIo,
  url : String,
  _max_bytes : Int,
) -> HttpReply raise @posoco.RuntimeError {
  self.calls = self.calls + 1
  self.urls.push(url)
  if self.delay_ms > 0 {
    @async.sleep(self.delay_ms) catch {
      _ => ()
    }
  }
  match self.replies.get(self.calls - 1) {
    Some(reply) => reply
    None =>
      raise @posoco.RuntimeError::InvocationFailed(
        "webfetch: fake io out of scripted replies",
      )
  }
}

///|
/// A WebFetchTools wired to a scripted FakeHttpIo; the io handle comes back
/// so tests can assert how many fetches ran and which URLs were requested.
fn wf_tools(
  replies : Array[HttpReply],
  max_chars? : Int = 50_000,
  timeout_ms? : Int = 30_000,
  delay_ms? : Int = 0,
) -> (WebFetchTools, FakeHttpIo) {
  let io : FakeHttpIo = { replies, urls: [], calls: 0, delay_ms, }
  let tools = WebFetchTools::WebFetchTools(
    max_chars~,
    timeout_ms~,
    io=Some(io as &HttpIo),
  )
  (tools, io)
}

///|
fn wf_call(url : String, offset? : Int) -> @posoco.ToolCall {
  let fields : Array[(String, Json)] = [("url", Json::string(url))]
  match offset {
    Some(o) => fields.push(("offset", Json::number(o.to_double())))
    None => ()
  }
  {
    call_id: @posoco.CallId::unchecked("wf-test"),
    name: @posoco.ToolName::unchecked("webfetch"),
    arguments: Json::object(Map::from_array(fields)),
  }
}

///|
async fn try_wf(
  tools : WebFetchTools,
  call : @posoco.ToolCall,
) -> Result[@posoco.ToolOutcome, @posoco.RuntimeError] {
  Ok(tools.execute("webfetch", call)) catch {
    error => Err(error)
  }
}

///|
fn try_args(args : Json) -> Result[(ParsedUrl, Int?), @posoco.RuntimeError] {
  Ok(extract_fetch_args(args)) catch {
    error => Err(error)
  }
}

///|
fn ok_page(
  outcome : Result[@posoco.ToolOutcome, @posoco.RuntimeError],
) -> (String, Json?) raise {
  match outcome {
    Ok(@posoco.ToolOutcome::Success(content~, structured~)) =>
      (content, structured)
    _ => fail("expected a Success outcome")
  }
}

///|
fn err_page(
  outcome : Result[@posoco.ToolOutcome, @posoco.RuntimeError],
) -> String raise {
  match outcome {
    Ok(@posoco.ToolOutcome::ToolReportedError(content~, structured=_)) =>
      content
    _ => fail("expected a ToolReportedError outcome")
  }
}

///|
fn ok_page_object(
  outcome : Result[@posoco.ToolOutcome, @posoco.RuntimeError],
) -> (String, Map[String, Json]) raise {
  let (content, structured) = ok_page(outcome)
  match structured {
    Some(Object(m)) => (content, m)
    _ => fail("expected a structured object payload")
  }
}

///|
/// ——— extract_fetch_args ———

///|
test "wf args rejects malformed input" {
  let missing = try_args(Json::object(Map::from_array([])))
  match missing {
    Err(@posoco.RuntimeError::UnknownTool(message)) =>
      inspect(message, content="webfetch: missing 'url'")
    _ => fail("expected UnknownTool for missing url")
  }
  let wrong_type = try_args(
    Json::object(Map::from_array([("url", Json::number(1.0))])),
  )
  match wrong_type {
    Err(@posoco.RuntimeError::UnknownTool(message)) =>
      inspect(message, content="webfetch: 'url' argument must be a string")
    _ => fail("expected UnknownTool for non-string url")
  }
  let not_object = try_args(Json::string("https://ex.com"))
  match not_object {
    Err(@posoco.RuntimeError::UnknownTool(message)) =>
      inspect(message, content="webfetch: arguments must be a JSON object")
    _ => fail("expected UnknownTool for non-object arguments")
  }
  let bad_offset = try_args(
    Json::object(
      Map::from_array([
        ("url", Json::string("https://ex.com")),
        ("offset", Json::string("3")),
      ]),
    ),
  )
  match bad_offset {
    Err(@posoco.RuntimeError::UnknownTool(message)) =>
      inspect(message, content="webfetch: optional 'offset' must be an integer")
    _ => fail("expected UnknownTool for non-integer offset")
  }
}

///|
test "wf args rejects bad url values" {
  let negative = try_args(
    Json::object(
      Map::from_array([
        ("url", Json::string("https://ex.com")),
        ("offset", Json::number(-1.0)),
      ]),
    ),
  )
  match negative {
    Err(@posoco.RuntimeError::UnknownTool(message)) =>
      inspect(
        message,
        content="webfetch: 'offset' must be a non-negative integer",
      )
    _ => fail("expected UnknownTool for negative offset")
  }
  let long_url = "https://ex.com/" + "a".repeat(2000)
  let too_long = try_args(
    Json::object(Map::from_array([("url", Json::string(long_url))])),
  )
  match too_long {
    Err(@posoco.RuntimeError::UnknownTool(message)) =>
      inspect(
        message,
        content="webfetch: 'url' exceeds the 2000 character limit",
      )
    _ => fail("expected UnknownTool for over-long url")
  }
  let ftp = try_args(
    Json::object(Map::from_array([("url", Json::string("ftp://ex.com/f"))])),
  )
  match ftp {
    Err(@posoco.RuntimeError::UnknownTool(message)) =>
      inspect(
        message,
        content="webfetch: 'url' must be an absolute http/https URL",
      )
    _ => fail("expected UnknownTool for non-http scheme")
  }
  let relative = try_args(
    Json::object(Map::from_array([("url", Json::string("/just/a/path"))])),
  )
  match relative {
    Err(@posoco.RuntimeError::UnknownTool(message)) =>
      inspect(
        message,
        content="webfetch: 'url' must be an absolute http/https URL",
      )
    _ => fail("expected UnknownTool for relative url")
  }
}

///|
test "wf args parses url and offset" {
  guard try_args(
      Json::object(
        Map::from_array([
          ("url", Json::string("https://ex.com/p?q=1")),
          ("offset", Json::number(7.0)),
        ]),
      ),
    )
    is Ok((parsed, offset)) else {
    fail("expected arguments to parse")
  }
  inspect(parsed.to_url_string(), content="https://ex.com/p?q=1")
  guard offset is Some(7) else { fail("expected offset 7") }
}

///|
/// ——— dispatch_content_type ———

///|
test "wf dispatch html converts to markdown" {
  guard dispatch_content_type(
      "text/html; charset=utf-8", "<p>just text</p>", "https://ex.com/page",
    )
    is Some((title, markdown)) else {
    fail("expected html conversion")
  }
  inspect(title, content="page")
  inspect(markdown, content="just text")
}

///|
test "wf dispatch passes text and json through" {
  let entries : Array[(String, String, String, String)] = [
    ("text/markdown", "# Hi", "https://ex.com/docs/readme", "readme"),
    ("text/plain", "abc", "https://ex.com/a.txt", "a.txt"),
    ("application/json", "{}", "https://ex.com/api/data", "data"),
    ("application/ld+json", "{}", "https://ex.com/x", "x"),
    ("text/markdown;charset=utf-8", "body", "https://ex.com/p", "p"),
  ]
  for entry in entries {
    let (ct, body, url, want_title) = entry
    guard dispatch_content_type(ct, body, url) is Some((title, content)) else {
      fail("expected passthrough for \{ct}")
    }
    assert_true(title == want_title)
    assert_true(content == body)
  }
}

///|
test "wf dispatch rejects unsupported types" {
  inspect(
    dispatch_content_type("application/pdf", "%PDF", "https://ex.com/f") is None,
    content="true",
  )
  inspect(
    dispatch_content_type("image/png", "png-bytes", "https://ex.com/f") is None,
    content="true",
  )
  inspect(
    dispatch_content_type("", "x", "https://ex.com/f") is None,
    content="true",
  )
}

///|
test "wf url title falls back to host" {
  inspect(url_title("https://ex.com/"), content="ex.com")
  inspect(url_title("https://ex.com"), content="ex.com")
  inspect(url_title("https://ex.com/a/b.txt?q=1"), content="b.txt")
  inspect(url_title("https://ex.com:8443/"), content="ex.com")
}

///|
/// ——— execute: redirects ———

///|
async test "wf stops at cross-host redirect" {
  let (tools, io) = wf_tools([
    HttpReply::{
      status: 301,
      reason: "Moved Permanently",
      content_type: "",
      location: Some("https://other.org/page"),
      body: "",
      bytes_read: 0,
      truncated: false,
    },
  ])
  let (content, structured) = ok_page(
    try_wf(tools, wf_call("https://ex.com/a")),
  )
  inspect(
    content,
    content="Redirect: https://ex.com/a redirects to https://other.org/page (different host; not followed automatically for safety). If you trust this target, call webfetch with url=https://other.org/page.",
  )
  inspect(io.calls, content="1")
  match structured {
    Some(Object(m)) => {
      guard m.get("redirect_to") is Some(String(target)) else {
        fail("expected redirect_to in structured payload")
      }
      inspect(target, content="https://other.org/page")
    }
    _ => fail("expected a structured object payload")
  }
}

///|
async test "wf follows same-host redirect" {
  let (tools, io) = wf_tools([
    HttpReply::{
      status: 301,
      reason: "Moved Permanently",
      content_type: "",
      location: Some("/b"),
      body: "",
      bytes_read: 0,
      truncated: false,
    },
    HttpReply::{
      status: 200,
      reason: "OK",
      content_type: "text/plain",
      location: None,
      body: "hello",
      bytes_read: 5,
      truncated: false,
    },
  ])
  let (content, _) = ok_page(try_wf(tools, wf_call("https://ex.com/a")))
  inspect(
    content,
    content="Title: b\nURL: https://ex.com/b\nContent-Type: text/plain\n\nhello",
  )
  inspect(io.calls, content="2")
}

///|
async test "wf refuses private redirect target" {
  let (tools, io) = wf_tools([
    HttpReply::{
      status: 302,
      reason: "Found",
      content_type: "",
      location: Some("http://127.0.0.1/x"),
      body: "",
      bytes_read: 0,
      truncated: false,
    },
  ])
  let content = err_page(try_wf(tools, wf_call("https://ex.com/a")))
  inspect(
    content,
    content="webfetch: host '127.0.0.1' is not allowed (private, local, or blocked address)",
  )
  inspect(io.calls, content="1")
}

///|
async test "wf fails after five same-host hops" {
  let (tools, io) = wf_tools(
    Array::make(6, HttpReply::{
      status: 302,
      reason: "Found",
      content_type: "",
      location: Some("/next"),
      body: "",
      bytes_read: 0,
      truncated: false,
    }),
  )
  let content = err_page(try_wf(tools, wf_call("https://ex.com/a")))
  inspect(
    content,
    content="webfetch: too many redirects (5) following 'https://ex.com/a'",
  )
  inspect(io.calls, content="6")
}

///|
async test "wf reports 3xx without Location" {
  let (tools, io) = wf_tools([
    HttpReply::{
      status: 302,
      reason: "Found",
      content_type: "",
      location: None,
      body: "",
      bytes_read: 0,
      truncated: false,
    },
  ])
  let content = err_page(try_wf(tools, wf_call("https://ex.com/a")))
  inspect(
    content,
    content="webfetch: request to 'https://ex.com/a' failed: redirect without Location header",
  )
  inspect(io.calls, content="1")
}

///|
async test "wf formats 404 as HttpError" {
  let (tools, io) = wf_tools([
    HttpReply::{
      status: 404,
      reason: "Not Found",
      content_type: "text/plain",
      location: None,
      body: "nope",
      bytes_read: 4,
      truncated: false,
    },
  ])
  let content = err_page(try_wf(tools, wf_call("https://ex.com/a")))
  inspect(
    content,
    content="webfetch: HTTP 404 Not Found for 'https://ex.com/a' — the page may have moved; try the site index or a search",
  )
  inspect(io.calls, content="1")
}

///|
async test "wf blocks private host before fetching" {
  let (tools, io) = wf_tools([])
  let content = err_page(try_wf(tools, wf_call("http://127.0.0.1/x")))
  inspect(
    content,
    content="webfetch: host '127.0.0.1' is not allowed (private, local, or blocked address)",
  )
  inspect(io.calls, content="0")
}

///|
/// ——— execute: cache and slicing ———

///|
async test "wf caches and serves the second call" {
  let (tools, io) = wf_tools([
    HttpReply::{
      status: 200,
      reason: "OK",
      content_type: "text/plain",
      location: None,
      body: "hello",
      bytes_read: 5,
      truncated: false,
    },
  ])
  let (first_content, _) = ok_page(
    try_wf(tools, wf_call("https://ex.com/cache")),
  )
  inspect(
    first_content,
    content="Title: cache\nURL: https://ex.com/cache\nContent-Type: text/plain\n\nhello",
  )
  let (second_content, m) = ok_page_object(
    try_wf(tools, wf_call("https://ex.com/cache")),
  )
  assert_true(second_content == first_content)
  guard m.get("cached") is Some(True) else {
    fail("expected cached=true on the second call")
  }
  inspect(io.calls, content="1")
}

///|
async test "wf paginates and continues via offset" {
  let (tools, io) = wf_tools(
    [
      HttpReply::{
        status: 200,
        reason: "OK",
        content_type: "text/plain",
        location: None,
        body: "hello",
        bytes_read: 5,
        truncated: false,
      },
    ],
    max_chars=3,
  )
  let (first_content, first_structured) = ok_page(
    try_wf(tools, wf_call("https://ex.com/slice")),
  )
  inspect(
    first_content,
    content="Title: slice\nURL: https://ex.com/slice\nContent-Type: text/plain\n\nhel\n\n… [showing characters 0–3 of 5; call webfetch with offset=3 to continue]",
  )
  match first_structured {
    Some(Object(m)) => {
      guard m.get("truncated") is Some(True) else {
        fail("expected truncated=true on the first page")
      }
    }
    _ => fail("expected a structured object payload")
  }
  let (second_content, _) = ok_page(
    try_wf(tools, wf_call("https://ex.com/slice", offset=3)),
  )
  inspect(
    second_content,
    content="Title: slice\nURL: https://ex.com/slice\nContent-Type: text/plain\n\nlo",
  )
  // The continuation slices from the cache: still exactly one fetch.
  inspect(io.calls, content="1")
}

///|
async test "wf reports offset past end" {
  let (tools, io) = wf_tools([
    HttpReply::{
      status: 200,
      reason: "OK",
      content_type: "text/plain",
      location: None,
      body: "hello",
      bytes_read: 5,
      truncated: false,
    },
  ])
  let content = err_page(
    try_wf(tools, wf_call("https://ex.com/slice", offset=99)),
  )
  inspect(
    content,
    content="webfetch: offset 99 is past the end of the content (total 5 characters) for 'https://ex.com/slice'",
  )
  inspect(io.calls, content="1")
}

///|
async test "wf reports unsupported content type" {
  let pdf = HttpReply::{
    status: 200,
    reason: "OK",
    content_type: "application/pdf",
    location: None,
    body: "%PDF",
    bytes_read: 4,
    truncated: false,
  }
  let (tools, io) = wf_tools([pdf, pdf])
  let content = err_page(try_wf(tools, wf_call("https://ex.com/file")))
  inspect(
    content,
    content="webfetch: unsupported content-type 'application/pdf' for 'https://ex.com/file' — this tool returns text, markdown, and JSON only",
  )
  // A failed dispatch is not cached: the retry refetches.
  let again = err_page(try_wf(tools, wf_call("https://ex.com/file")))
  assert_true(again == content)
  inspect(io.calls, content="2")
}

///|
async test "wf reports fetch timeout" {
  let (tools, io) = wf_tools(
    [
      HttpReply::{
        status: 200,
        reason: "OK",
        content_type: "text/plain",
        location: None,
        body: "hello",
        bytes_read: 5,
        truncated: false,
      },
    ],
    timeout_ms=50,
    delay_ms=200,
  )
  let content = err_page(try_wf(tools, wf_call("https://ex.com/slow")))
  inspect(
    content,
    content="webfetch: request to 'https://ex.com/slow' timed out after 50ms — the site may be slow or blocking automated clients; retrying or using a different source may help",
  )
  // The slow fetch started but never produced a reply.
  inspect(io.calls, content="1")
}

///|
async test "wf resolves relative redirect Location" {
  let (tools, io) = wf_tools([
    HttpReply::{
      status: 301,
      reason: "Moved Permanently",
      content_type: "",
      location: Some("docs/page"),
      body: "",
      bytes_read: 0,
      truncated: false,
    },
    HttpReply::{
      status: 200,
      reason: "OK",
      content_type: "text/markdown",
      location: None,
      body: "# doc",
      bytes_read: 6,
      truncated: false,
    },
  ])
  let (content, _) = ok_page(try_wf(tools, wf_call("https://ex.com/")))
  inspect(
    content,
    content="Title: page\nURL: https://ex.com/docs/page\nContent-Type: text/markdown\n\n# doc",
  )
  inspect(io.calls, content="2")
  // The second hop resolved 'docs/page' against the base path '/'.
  inspect(io.urls[0], content="https://ex.com/")
  inspect(io.urls[1], content="https://ex.com/docs/page")
}

///|
async test "wf reports response too large when the body hits the byte cap" {
  let big = HttpReply::{
    status: 200,
    reason: "OK",
    content_type: "text/plain",
    location: None,
    body: "big",
    bytes_read: 5_242_880,
    truncated: true,
  }
  let (tools, io) = wf_tools([big, big])
  let content = err_page(try_wf(tools, wf_call("https://ex.com/big")))
  inspect(
    content,
    content="webfetch: response too large (5242880 bytes exceeds the 5 MB cap) for 'https://ex.com/big'",
  )
  // A failed dispatch is not cached: the retry refetches.
  let again = err_page(try_wf(tools, wf_call("https://ex.com/big")))
  assert_true(again == content)
  inspect(io.calls, content="2")
}

///|
async test "wf treats truncated=false as a complete reply even at the cap" {
  let (tools, io) = wf_tools([
    HttpReply::{
      status: 200,
      reason: "OK",
      content_type: "text/plain",
      location: None,
      body: "hello",
      bytes_read: 5_242_880,
      truncated: false,
    },
  ])
  let (content, _) = ok_page(try_wf(tools, wf_call("https://ex.com/exact")))
  inspect(
    content,
    content="Title: exact\nURL: https://ex.com/exact\nContent-Type: text/plain\n\nhello",
  )
  inspect(io.calls, content="1")
}
