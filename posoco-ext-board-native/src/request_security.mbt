///|
fn board_hex(bytes : Bytes) -> String {
  let hex = "0123456789abcdef"
  let out = StringBuilder()
  for byte in bytes {
    let n = byte.to_int()
    out.write_char(hex.get_char((n >> 4) & 0x0f).unwrap())
    out.write_char(hex.get_char(n & 0x0f).unwrap())
  }
  out.to_string()
}

///|
/// Mint a fresh 256-bit instance secret. There is deliberately no weak
/// fallback: failure to obtain OS entropy refuses control-plane startup.
fn board_instance_token() -> Result[String, String] {
  let bytes = board_random_bytes_probe(32)
  if bytes.length() != 32 {
    Err("board: operating-system entropy source unavailable")
  } else {
    Ok(board_hex(bytes))
  }
}

///|
fn board_expected_host(endpoint : BoardEndpoint) -> String {
  endpoint.host + ":" + endpoint.port.to_string()
}

///|
fn board_request_host_ok(
  request : @moonback.Request,
  endpoint : BoardEndpoint,
) -> Bool {
  match request.headers.get("host") {
    Some(value) => value == board_expected_host(endpoint)
    None => false
  }
}

///|
/// Missing Origin is allowed for non-browser local clients. If a browser sends
/// Origin, it must be the exact same loopback origin.
fn board_request_origin_ok(
  request : @moonback.Request,
  endpoint : BoardEndpoint,
) -> Bool {
  match request.headers.get("origin") {
    None => true
    Some(value) => value == endpoint.base_url()
  }
}

///|
fn board_request_token_ok(request : @moonback.Request, token : String) -> Bool {
  request.query().get("token") == Some(token)
}

///|
/// Require a valid Host on all requests and a matching Origin on WebSockets.
fn board_request_source_ok(
  request : @moonback.Request,
  endpoint : BoardEndpoint,
) -> Bool {
  board_request_host_ok(request, endpoint) &&
  (request.path != "/ws" || board_request_origin_ok(request, endpoint))
}

///|
/// Health and manifest-declared static resources are the only public paths.
fn board_token_required(path : StringView, public_assets : Set[String]) -> Bool {
  path != "/health" && !public_assets.contains(path.to_owned())
}

///|
fn board_response_headers() -> Map[String, String] {
  { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" }
}

///|
/// Security runs before MoonBack routing and the static middleware, including
/// their 404/405 responses. Only `/health` and manifest asset paths other than
/// the root document are token-free.
fn board_security(
  endpoint : BoardEndpoint,
  token : String,
  public_assets : Set[String],
) -> @moonback.Middleware {
  @moonback.Middleware(next => {
    (req, res) => {
      if !board_request_source_ok(req, endpoint) {
        res.send_text("forbidden", status=403, headers=board_response_headers())
      } else if board_token_required(req.path, public_assets) &&
        !board_request_token_ok(req, token) {
        res.send_text(
          "unauthorized",
          status=401,
          headers=board_response_headers(),
        )
      } else {
        next(
          req,
          @moonback.Responder((status, headers) => {
            let headers = headers.to_mut()
            headers.set("Cache-Control", "no-store")
            headers.set("X-Content-Type-Options", "nosniff")
            res.respond(status~, headers~)
          }),
        )
      }
    }
  })
}

