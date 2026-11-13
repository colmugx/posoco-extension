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
  backend~ : @backend.BoardBackend? = None,
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
          "protocol_version": Json(@protocol.protocol_version()),
          "host": Json(endpoint.host),
          "port": Json(endpoint.port),
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
