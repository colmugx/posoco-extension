///|
pub struct NativeBoardWebServer {
  /// The single authoritative seam: snapshot bootstrap, command handling
  /// and the live stream all come from the installed backend. `None` means
  /// the server is only presentation plumbing and refuses to bind.
  priv mut backend : @backend.BoardBackend?
  priv mut listener : @http.Server?
  priv mut app : @moonback.App?
  priv mut endpoint : BoardEndpoint?
  priv mut token : String?
  priv mut alive : Bool
  priv mut closing : Bool
  priv mut error : String?
  priv stop : @async.CondVar
  priv mut serving : Bool
}

///|
pub fn NativeBoardWebServer::NativeBoardWebServer(
  backend? : @backend.BoardBackend? = None,
) -> NativeBoardWebServer {
  {
    backend,
    listener: None,
    app: None,
    endpoint: None,
    token: None,
    alive: false,
    closing: false,
    error: None,
    stop: @async.CondVar::Cond(),
    serving: false,
  }
}

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
      if !board_request_host_ok(req, endpoint) ||
        (req.path == "/ws" && !board_request_origin_ok(req, endpoint)) {
        res.send_text("forbidden", status=403, headers=board_response_headers())
      } else if req.path != "/health" &&
        !public_assets.contains(req.path.to_owned()) &&
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

///|
/// Board control-plane paths are reserved from the embedded static namespace.
/// Keep the whole `/api` namespace reserved for future authenticated HTTP APIs.
fn board_control_path(path : String) -> Bool {
  path == "/health" ||
  path == "/ws" ||
  path == "/api" ||
  path.has_prefix("/api/")
}

///|
/// Public static paths come from the actual embedded manifest. `/index.html`
/// and `/` stay token-gated, while control-plane paths are never public even
/// if a malformed or hand-built asset map contains a collision.
fn board_public_asset_paths(assets : Map[String, Bytes]) -> Set[String] {
  Set::from_iter(
    assets
      .keys()
      .filter(path =>
        path != "/" && path != "/index.html" && !board_control_path(path)
      ),
  )
}

///|
/// Static resources must never shadow Board control-plane routes. The asset
/// generator rejects these collisions too; this runtime guard is intentional
/// defense in depth for hand-built or stale manifests.
fn board_static_assets(assets : Map[String, Bytes]) -> @moonback.Middleware {
  let resources = @static.from_assets(
    assets,
    rewrite_trailing_slash_index=true,
  )
  @moonback.Middleware(next => {
    let serve = (resources.0)(next)
    (req, res) => {
      if board_control_path(req.path) {
        next(req, res)
      } else {
        serve(req, res)
      }
    }
  })
}

///|
async fn NativeBoardWebServer::make_app(
  self : NativeBoardWebServer,
  endpoint : BoardEndpoint,
  token : String,
) -> @moonback.App {
  let assets = web_assets()
  @moonback.App(
    ctx => {
      ctx.add_middleware(
        board_security(endpoint, token, board_public_asset_paths(assets)),
      )
      ctx.add_middleware(board_static_assets(assets))
      ctx.get("/health", (_req, res) => {
        res.send_json({ "ok": true, "service": "posoco-ext-board" })
      })
      ctx.get("/api/bootstrap", (_req, res) => {
        res.send_json({
          "protocol_version": @protocol.protocol_version().to_json(),
          "host": endpoint.host.to_json(),
          "port": endpoint.port.to_json(),
          "ws_path": "/ws",
        })
      })
      ctx.get("/ws", (req, res) => {
        let ws = res.upgrade(req)
        defer ws.close()
        if !self.closing && self.token == Some(token) {
          self.serve_ws(ws)
        }
      })
    },
    config=@moonback.Config(stop_timeout=1.0),
  )
}

///|
pub impl BoardWebServer for NativeBoardWebServer with fn bind(self) {
  if self.backend is None {
    return Err("board backend not installed")
  }
  match self.endpoint {
    Some(value) if self.alive => return Ok(value)
    _ => ()
  }
  if self.serving {
    return Err("board: previous server worker is still stopping")
  }
  let token = match board_instance_token() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let listener = @moonback.listen(host="127.0.0.1", port=0) catch {
    error => {
      let message = "board: bind failed: " + error.to_string()
      self.error = Some(message)
      return Err(message)
    }
  }
  let endpoint : BoardEndpoint = {
    host: "127.0.0.1",
    port: listener.addr.port(),
  }
  let app = self.make_app(endpoint, token) catch {
    error => {
      listener.close()
      let message = "board: routes failed: " + error.to_string()
      self.error = Some(message)
      return Err(message)
    }
  }
  self.listener = Some(listener)
  self.app = Some(app)
  self.endpoint = Some(endpoint)
  self.token = Some(token)
  self.alive = true
  self.closing = false
  self.error = None
  Ok(endpoint)
}

///|
pub impl BoardWebServer for NativeBoardWebServer with fn run(self) {
  let (app, listener) = match (self.app, self.listener) {
    (Some(app), Some(listener)) => (app, listener)
    _ => return Err("board: server is not bound")
  }
  if self.serving {
    return Err("board: server worker already running")
  }
  self.serving = true
  defer {
    self.serving = false
    app.close()
  }
  // Closing signals cancellation of App::serve, not just listener.close:
  // protected WebSocket handlers must be drained too. MoonBack's 1s grace
  // remains below the runtime Supervisor's 5s cancel-and-wait bound.
  let outcome : Result[Unit, Error] = Ok(
    @async.any([
      () => app.serve(listener),
      () => {
        while !self.closing {
          self.stop.wait()
        }
      },
    ]),
  ) catch {
    error => Err(error)
  }
  self.alive = false
  match outcome {
    Ok(_) => Ok(())
    Err(error) =>
      if self.closing {
        Ok(())
      } else {
        let message = "board: server failed: " + error.to_string()
        self.error = Some(message)
        Err(message)
      }
  }
}

///|
pub impl BoardWebServer for NativeBoardWebServer with fn browser_url(self) {
  match (self.endpoint, self.token) {
    (Some(endpoint), Some(token)) if self.alive =>
      Some(endpoint.base_url() + "/?token=" + token)
    _ => None
  }
}

///|
pub impl BoardWebServer for NativeBoardWebServer with fn close(self) {
  self.closing = true
  self.stop.broadcast()
  self.alive = false
  // Before run, the adapter owns the bound listener. Once serving, MoonBack
  // owns its teardown and receives cancellation through the stop signal.
  if !self.serving {
    match self.listener {
      Some(listener) => listener.close()
      None => ()
    }
    match self.app {
      Some(app) => app.close()
      None => ()
    }
  }
  self.listener = None
  self.app = None
  self.endpoint = None
  self.token = None
}

///|
pub impl BoardWebServer for NativeBoardWebServer with fn is_alive(self) {
  self.alive
}

///|
pub impl BoardWebServer for NativeBoardWebServer with fn last_error(self) {
  self.error
}

///|
pub impl BoardWebServer for NativeBoardWebServer with fn set_backend(
  self,
  backend : @backend.BoardBackend,
) -> Unit {
  // A listener fixes its authoritative stream until it is stopped.
  if !self.alive && !self.serving && self.listener is None {
    self.backend = Some(backend)
  }
}

///|
pub extend NativeBoardWebServer with BoardWebServer::{
  bind,
  run,
  browser_url,
  close,
  is_alive,
  last_error,
  set_backend,
}
