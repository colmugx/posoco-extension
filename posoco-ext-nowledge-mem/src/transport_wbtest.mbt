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
