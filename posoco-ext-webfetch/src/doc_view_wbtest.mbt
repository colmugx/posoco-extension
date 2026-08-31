///|
test "doc_view slice_chars pages from zero" {
  guard slice_chars("abcdefghij", 0, 4) is Some(s) else {
    fail("expected a slice")
  }
  inspect(
    s.body,
    content=(
      #|abcd
    ),
  )
  inspect(
    s.offset,
    content=(
      #|0
    ),
  )
  inspect(
    s.end,
    content=(
      #|4
    ),
  )
  inspect(
    s.total,
    content=(
      #|10
    ),
  )
  inspect(
    s.truncated,
    content=(
      #|true
    ),
  )
}

///|
test "doc_view slice_chars continues from an offset" {
  guard slice_chars("abcdefghij", 4, 4) is Some(s) else {
    fail("expected a slice")
  }
  inspect(
    s.body,
    content=(
      #|efgh
    ),
  )
  inspect(
    s.offset,
    content=(
      #|4
    ),
  )
  inspect(
    s.end,
    content=(
      #|8
    ),
  )
  inspect(
    s.truncated,
    content=(
      #|true
    ),
  )
}

///|
test "doc_view slice_chars ending exactly at the end is not truncated" {
  guard slice_chars("abcdefghij", 4, 6) is Some(s) else {
    fail("expected a slice")
  }
  inspect(
    s.body,
    content=(
      #|efghij
    ),
  )
  inspect(
    s.end,
    content=(
      #|10
    ),
  )
  inspect(
    s.truncated,
    content=(
      #|false
    ),
  )
}

///|
test "doc_view slice_chars rejects bad offsets" {
  inspect(
    slice_chars("abc", 3, 2) is None,
    content=(
      #|true
    ),
  )
  inspect(
    slice_chars("abc", 5, 2) is None,
    content=(
      #|true
    ),
  )
  inspect(
    slice_chars("abc", -1, 2) is None,
    content=(
      #|true
    ),
  )
}

///|
test "doc_view slice_chars counts scalars and never tears surrogate pairs" {
  // 你 好 😀 世 界 = 5 scalars, 6 UTF-16 code units.
  guard slice_chars("你好😀世界", 2, 2) is Some(s) else {
    fail("expected a slice")
  }
  inspect(
    s.body,
    content=(
      #|😀世
    ),
  )
  inspect(
    s.total,
    content=(
      #|5
    ),
  )
  inspect(
    s.end,
    content=(
      #|4
    ),
  )
  inspect(
    s.truncated,
    content=(
      #|true
    ),
  )
}

///|
test "doc_view format_page renders header and body without footer when complete" {
  guard slice_chars("hello world", 0, 11) is Some(s) else {
    fail("expected a slice")
  }
  inspect(
    format_page("Hi", "https://e.com/a", "text/markdown", s),
    content=(
      #|Title: Hi
      #|URL: https://e.com/a
      #|Content-Type: text/markdown
      #|
      #|hello world
    ),
  )
}

///|
test "doc_view format_page appends continuation footer when truncated" {
  guard slice_chars("0123456789", 0, 3) is Some(s) else {
    fail("expected a slice")
  }
  inspect(
    format_page("Hi", "https://e.com/a", "text/markdown", s),
    content=(
      #|Title: Hi
      #|URL: https://e.com/a
      #|Content-Type: text/markdown
      #|
      #|012
      #|
      #|… [showing characters 0–3 of 10; call webfetch with offset=3 to continue]
    ),
  )
}

///|
test "doc_view format_page omits footer when a page ends exactly at the end" {
  guard slice_chars("0123456789", 8, 3) is Some(s) else {
    fail("expected a slice")
  }
  inspect(
    format_page("Hi", "https://e.com/a", "text/markdown", s),
    content=(
      #|Title: Hi
      #|URL: https://e.com/a
      #|Content-Type: text/markdown
      #|
      #|89
    ),
  )
}

///|
test "doc_view format_redirect names both urls and the explicit opt-in" {
  inspect(
    format_redirect("https://a.com/x", "https://b.com/y"),
    content=(
      #|Redirect: https://a.com/x redirects to https://b.com/y (different host; not followed automatically for safety). If you trust this target, call webfetch with url=https://b.com/y.
    ),
  )
}

///|
test "doc_view format_error http advice buckets" {
  inspect(
    format_error(
      HttpError(status=404, reason="Not Found", url="https://e.com/a"),
    ),
    content=(
      #|webfetch: HTTP 404 Not Found for 'https://e.com/a' — the page may have moved; try the site index or a search
    ),
  )
  inspect(
    format_error(
      HttpError(status=403, reason="Forbidden", url="https://e.com/a"),
    ),
    content=(
      #|webfetch: HTTP 403 Forbidden for 'https://e.com/a' — the site may block automated clients; try a different source
    ),
  )
  inspect(
    format_error(
      HttpError(status=503, reason="Service Unavailable", url="https://e.com/a"),
    ),
    content=(
      #|webfetch: HTTP 503 Service Unavailable for 'https://e.com/a' — the server failed; retrying later may help
    ),
  )
  inspect(
    format_error(
      HttpError(status=400, reason="Bad Request", url="https://e.com/a"),
    ),
    content=(
      #|webfetch: HTTP 400 Bad Request for 'https://e.com/a' — check the URL and parameters
    ),
  )
}

///|
test "doc_view format_error remaining kinds" {
  inspect(
    format_error(TooLarge(bytes=6291456, url="https://e.com/a")),
    content=(
      #|webfetch: response too large (6291456 bytes exceeds the 5 MB cap) for 'https://e.com/a'
    ),
  )
  inspect(
    format_error(TimedOut(ms=30000, url="https://e.com/a")),
    content=(
      #|webfetch: request to 'https://e.com/a' timed out after 30000ms — the site may be slow or blocking automated clients; retrying or using a different source may help
    ),
  )
  inspect(
    format_error(UnsupportedType(ct="image/png", url="https://e.com/a")),
    content=(
      #|webfetch: unsupported content-type 'image/png' for 'https://e.com/a' — this tool returns text, markdown, and JSON only
    ),
  )
  inspect(
    format_error(HostBlocked(host="169.254.169.254")),
    content=(
      #|webfetch: host '169.254.169.254' is not allowed (private, local, or blocked address)
    ),
  )
  inspect(
    format_error(TooManyRedirects(hops=10, url="https://e.com/a")),
    content=(
      #|webfetch: too many redirects (10) following 'https://e.com/a'
    ),
  )
  inspect(
    format_error(Transport(msg="connection reset", url="https://e.com/a")),
    content=(
      #|webfetch: request to 'https://e.com/a' failed: connection reset
    ),
  )
  inspect(
    format_error(OffsetPastEnd(offset=120, total=100, url="https://e.com/a")),
    content=(
      #|webfetch: offset 120 is past the end of the content (total 100 characters) for 'https://e.com/a'
    ),
  )
}

///|
test "doc_view structured_json field set and order" {
  json_inspect(
    structured_json(
      url_requested="https://e.com/a",
      url_final="https://e.com/final",
      status=200,
      content_type="text/markdown",
      bytes_fetched=1234,
      chars_total=5678,
      chars_returned=5000,
      offset=0,
      truncated=true,
      elapsed_ms=812,
      cached=false,
    ),
    content={
      "url_requested": "https://e.com/a",
      "url_final": "https://e.com/final",
      "status": 200,
      "content_type": "text/markdown",
      "bytes_fetched": 1234,
      "chars_total": 5678,
      "chars_returned": 5000,
      "offset": 0,
      "truncated": true,
      "elapsed_ms": 812,
      "cached": false,
    },
  )
}
