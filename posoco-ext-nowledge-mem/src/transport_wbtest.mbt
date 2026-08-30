///|
fn transport_test_config(api_key : String?) -> NmemConfig {
  {
    api_url: "http://127.0.0.1:14242",
    mcp_url: "http://127.0.0.1:14242/mcp",
    api_key,
    space: None,
    agent_id: None,
    host_agent_id: None,
    source_app: "posoco",
  }
}

///|
test "split_url: origin keeps scheme and port, path carries the rest" {
  guard split_url("http://127.0.0.1:14242/threads") is Some((origin, path)) else {
    fail("expected http origin with port")
  }
  inspect(origin, content="http://127.0.0.1:14242")
  inspect(path, content="/threads")
  guard split_url("https://mem.example.com/threads/t1/append")
    is Some((origin, path)) else {
    fail("expected https origin")
  }
  inspect(origin, content="https://mem.example.com")
  inspect(path, content="/threads/t1/append")
}

///|
test "split_url: missing path defaults to slash, with or without trailing slash" {
  guard split_url("https://mem.example.com") is Some((origin, path)) else {
    fail("expected split without path")
  }
  inspect(origin, content="https://mem.example.com")
  inspect(path, content="/")
  guard split_url("https://mem.example.com/") is Some((origin2, path2)) else {
    fail("expected split with trailing slash")
  }
  inspect(origin2, content="https://mem.example.com")
  inspect(path2, content="/")
}

///|
test "split_url: query string stays with the path" {
  guard split_url("http://h:1/threads?limit=5") is Some((origin, path)) else {
    fail("expected split with query")
  }
  inspect(origin, content="http://h:1")
  inspect(path, content="/threads?limit=5")
}

///|
test "split_url: rejects missing scheme, non-http scheme, and empty host" {
  guard split_url("127.0.0.1:14242/threads") is None else {
    fail("expected None without scheme")
  }
  guard split_url("ftp://host/x") is None else {
    fail("expected None for non-http scheme")
  }
  guard split_url("http:///threads") is None else {
    fail("expected None for empty host")
  }
  guard split_url("http://") is None else {
    fail("expected None for bare scheme")
  }
}

///|
test "split_url: rejects malformed ports" {
  guard split_url("http://host:/x") is None else {
    fail("expected None for empty port")
  }
  guard split_url("http://host:8o/x") is None else {
    fail("expected None for non-digit port")
  }
  guard split_url("http://:8080/x") is None else {
    fail("expected None for empty host with port")
  }
}

///|
test "split_url: bracketed ipv6 hosts with optional port" {
  guard split_url("http://[::1]:14242/threads") is Some((origin, path)) else {
    fail("expected ipv6 origin with port")
  }
  inspect(origin, content="http://[::1]:14242")
  inspect(path, content="/threads")
  guard split_url("http://[::1]/threads") is Some((origin2, path2)) else {
    fail("expected ipv6 origin without port")
  }
  inspect(origin2, content="http://[::1]")
  inspect(path2, content="/threads")
  guard split_url("http://[::1/threads") is None else {
    fail("expected None for unclosed bracket")
  }
  guard split_url("http://[::1]junk/threads") is None else {
    fail("expected None for junk after bracket")
  }
}

///|
test "nmem_request_headers: json content type only without api key" {
  let headers = nmem_request_headers(transport_test_config(None))
  inspect(headers.length(), content="1")
  guard headers.contains("Content-Type") else { fail("missing content type") }
  inspect(headers["Content-Type"], content="application/json")
  inspect(headers.contains("Authorization"), content="false")
  inspect(headers.contains("X-NMEM-API-Key"), content="false")
}

///|
test "nmem_request_headers: dual auth headers when api key is set" {
  let headers = nmem_request_headers(transport_test_config(Some("k-1")))
  inspect(headers.length(), content="3")
  guard headers.contains("Authorization") else { fail("missing bearer") }
  inspect(headers["Authorization"], content="Bearer k-1")
  guard headers.contains("X-NMEM-API-Key") else { fail("missing api key") }
  inspect(headers["X-NMEM-API-Key"], content="k-1")
}

///|
test "with_space_id: appends space_id to an object without one" {
  let body = Json::object(Map::from_array([("title", Json::string("t"))]))
  let injected = with_space_id(body, Some("sp1"))
  inspect(
    injected.stringify(),
    content="{\"title\":\"t\",\"space_id\":\"sp1\"}",
  )
  inspect(body.stringify(), content="{\"title\":\"t\"}")
}

///|
test "with_space_id: existing space_id is never overwritten" {
  let body = Json::object(
    Map::from_array([
      ("space_id", Json::string("orig")),
      ("flag", Json::boolean(true)),
    ]),
  )
  let result = with_space_id(body, Some("sp1"))
  inspect(result.stringify(), content="{\"space_id\":\"orig\",\"flag\":true}")
}

///|
test "with_space_id: none space and non-object bodies pass through" {
  let body = Json::object(Map::from_array([("title", Json::string("t"))]))
  inspect(with_space_id(body, None).stringify(), content="{\"title\":\"t\"}")
  let array_body = Json::array([Json::string("a")])
  inspect(with_space_id(array_body, Some("sp1")).stringify(), content="[\"a\"]")
}

///|
test "remote_api_fallback_urls: exact prefix collapses to the bare origin" {
  debug_inspect(
    remote_api_fallback_urls("https://mem.example.com/remote-api"),
    content="[\"https://mem.example.com\"]",
  )
  debug_inspect(
    remote_api_fallback_urls("https://mem.example.com:8443/remote-api"),
    content="[\"https://mem.example.com:8443\"]",
  )
}

///|
test "remote_api_fallback_urls: prefixed paths strip the remote-api segment" {
  debug_inspect(
    remote_api_fallback_urls("https://mem.example.com/remote-api/v1/threads"),
    content="[\"https://mem.example.com/v1/threads\"]",
  )
  debug_inspect(
    remote_api_fallback_urls("https://mem.example.com/remote-api/"),
    content="[\"https://mem.example.com/\"]",
  )
}

///|
test "remote_api_fallback_urls: local and malformed urls yield no fallbacks" {
  debug_inspect(
    remote_api_fallback_urls("http://127.0.0.1:14242/threads"),
    content="[]",
  )
  debug_inspect(
    remote_api_fallback_urls("https://mem.example.com/threads"),
    content="[]",
  )
  debug_inspect(
    remote_api_fallback_urls("mem.example.com/remote-api"),
    content="[]",
  )
  debug_inspect(
    remote_api_fallback_urls("ftp://mem.example.com/remote-api"),
    content="[]",
  )
  debug_inspect(remote_api_fallback_urls(""), content="[]")
}

///|
async test "post_json: url without a scheme fails fast without network io" {
  let transport = HttpNmemTransport::HttpNmemTransport()
  let result = NmemTransport::post_json(
    transport,
    "127.0.0.1:14242/threads",
    Map::from_array([]),
    Json::null(),
    timeout_ms=1000,
  )
  guard result is Err(message) else { fail("expected Err for schemeless url") }
  inspect(
    message,
    content="nmem transport failure (stage=split_url): invalid url: 127.0.0.1:14242/threads",
  )
}
