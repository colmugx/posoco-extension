///|
pub struct NativeBoardWebServer {
  mut server : @http.Server?
  mut endpoint : BoardEndpoint?
  mut token : String?
  mut alive : Bool
  mut closing : Bool
  mut error : String?
}

///|
pub fn NativeBoardWebServer::NativeBoardWebServer() -> NativeBoardWebServer {
  {
    server: None,
    endpoint: None,
    token: None,
    alive: false,
    closing: false,
    error: None,
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
fn board_query_param(path : String, key : String) -> String? {
  let query = match path.find("?") {
    Some(index) => path.exact_view(start=index + 1).to_owned()
    None => return None
  }
  let prefix = key + "="
  for part in query.split("&") {
    let value = part.to_owned()
    if value.has_prefix(prefix) {
      return Some(value.exact_view(start=prefix.length()).to_owned())
    }
  }
  None
}

///|
fn board_request_path(path : String) -> String {
  match path.find("?") {
    Some(index) => path.exact_view(end=index).to_owned()
    None => path
  }
}

///|
async fn board_send(
  conn : @http.ServerConnection,
  code : Int,
  reason : String,
  content_type : String,
  body : String,
) -> Unit {
  conn.send_response(
    code,
    reason,
    extra_headers={
      "Content-Type": content_type,
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  )
  conn.write(body)
  conn.end_response()
}

///|
fn board_expected_host(endpoint : BoardEndpoint) -> String {
  endpoint.host + ":" + endpoint.port.to_string()
}

///|
fn board_request_host_ok(
  request : @http.Request,
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
  request : @http.Request,
  endpoint : BoardEndpoint,
) -> Bool {
  match request.headers.get("origin") {
    None => true
    Some(value) => value == endpoint.base_url()
  }
}

///|
fn board_request_token_ok(
  request : @http.Request,
  token : String,
) -> Bool {
  board_query_param(request.path, "token") == Some(token)
}

///|
fn board_placeholder_page() -> String {
  "<!doctype html><html><head><meta charset=\"utf-8\"><title>Posoco Board</title></head>" +
  "<body><main><h1>Posoco Board</h1><p id=\"status\">connecting…</p></main>" +
  "<script>(function(){const q=new URLSearchParams(location.search);const t=q.get('token');" +
  "if(!t){document.getElementById('status').textContent='missing bootstrap token';return;}" +
  "const u='ws://'+location.host+'/ws?token='+encodeURIComponent(t);" +
  "const ws=new WebSocket(u);ws.onopen=()=>document.getElementById('status').textContent='connected';" +
  "ws.onclose=()=>document.getElementById('status').textContent='disconnected';" +
  "ws.onerror=()=>document.getElementById('status').textContent='connection error';})();</script>" +
  "</body></html>"
}

///|
async fn NativeBoardWebServer::handle_ws(
  self : NativeBoardWebServer,
  request : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  let endpoint = match self.endpoint {
    Some(value) => value
    None => {
      board_send(conn, 503, "Service Unavailable", "text/plain; charset=utf-8", "not running")
      return
    }
  }
  let token = match self.token {
    Some(value) => value
    None => {
      board_send(conn, 503, "Service Unavailable", "text/plain; charset=utf-8", "not running")
      return
    }
  }
  if !board_request_host_ok(request, endpoint) ||
    !board_request_origin_ok(request, endpoint) {
    board_send(conn, 403, "Forbidden", "text/plain; charset=utf-8", "forbidden")
    return
  }
  if !board_request_token_ok(request, token) {
    board_send(conn, 401, "Unauthorized", "text/plain; charset=utf-8", "unauthorized")
    return
  }
  let ws = @websocket.from_http_server(request, conn)
  defer ws.close()
  for ;; {
    let message = ws.recv() catch {
      @websocket.ConnectionClosed(_) => break
      _ => break
    }
    let _ = message.read_all()
  }
}

///|
async fn NativeBoardWebServer::handle_request(
  self : NativeBoardWebServer,
  request : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  let endpoint = match self.endpoint {
    Some(value) => value
    None => {
      board_send(conn, 503, "Service Unavailable", "text/plain; charset=utf-8", "not running")
      return
    }
  }
  if !board_request_host_ok(request, endpoint) {
    board_send(conn, 403, "Forbidden", "text/plain; charset=utf-8", "forbidden")
    return
  }
  let path = board_request_path(request.path)
  if path == "/health" {
    board_send(
      conn,
      200,
      "OK",
      "application/json; charset=utf-8",
      Json::object({
        "ok": Json::boolean(true),
        "service": Json::string("posoco-ext-board"),
      }).stringify(),
    )
    return
  }
  let token = match self.token {
    Some(value) => value
    None => {
      board_send(conn, 503, "Service Unavailable", "text/plain; charset=utf-8", "not running")
      return
    }
  }
  if path == "/ws" {
    self.handle_ws(request, conn)
    return
  }
  if !board_request_token_ok(request, token) {
    board_send(conn, 401, "Unauthorized", "text/plain; charset=utf-8", "unauthorized")
    return
  }
  match path {
    "/" =>
      board_send(
        conn,
        200,
        "OK",
        "text/html; charset=utf-8",
        board_placeholder_page(),
      )
    "/api/bootstrap" =>
      board_send(
        conn,
        200,
        "OK",
        "application/json; charset=utf-8",
        Json::object({
          "protocol_version": Json::number(@protocol.protocol_version().to_double()),
          "host": Json::string(endpoint.host),
          "port": Json::number(endpoint.port.to_double()),
          "ws_path": Json::string("/ws"),
        }).stringify(),
      )
    _ =>
      board_send(conn, 404, "Not Found", "text/plain; charset=utf-8", "not found")
  }
}

///|
pub impl BoardWebServer for NativeBoardWebServer with fn bind(self) {
  match self.endpoint {
    Some(value) if self.alive => return Ok(value)
    _ => ()
  }
  let token = match board_instance_token() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let server = Ok(@http.Server(@socket.Addr::parse("127.0.0.1:0"))) catch {
    error => Err(error)
  }
  match server {
    Err(error) => {
      let message = "board: bind failed: " + error.to_string()
      self.error = Some(message)
      Err(message)
    }
    Ok(server) => {
      let endpoint : BoardEndpoint = {
        host: "127.0.0.1",
        port: server.addr.port(),
      }
      self.server = Some(server)
      self.endpoint = Some(endpoint)
      self.token = Some(token)
      self.alive = true
      self.closing = false
      self.error = None
      Ok(endpoint)
    }
  }
}

///|
pub impl BoardWebServer for NativeBoardWebServer with fn run(self) {
  let server = match self.server {
    Some(value) => value
    None => return Err("board: server is not bound")
  }
  let outcome : Result[Unit, Error] = Ok(
    server.run_forever((request, _body, conn) => {
      self.handle_request(request, conn)
    }),
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
  self.alive = false
  match self.server {
    Some(server) => server.close()
    None => ()
  }
  self.server = None
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
pub struct NativeBrowserOpener {}

///|
pub fn NativeBrowserOpener::NativeBrowserOpener() -> NativeBrowserOpener {
  NativeBrowserOpener::{ }
}

///|
async fn board_run_opener(
  command : String,
  args : Array[String],
) -> Result[Unit, String] {
  let result : Result[Int, Error] = Ok(
    @process.run(command, args.clamped_view(), no_console_window=true),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(0) => Ok(())
    Ok(code) => Err("board: browser opener '\{command}' exited with \{code}")
    Err(error) => Err("board: browser opener '\{command}' failed: " + error.to_string())
  }
}

///|
pub impl BrowserOpener for NativeBrowserOpener with fn open(_self, url) {
  if @env.get_env_var("OS") == Some("Windows_NT") {
    return board_run_opener("cmd", ["/c", "start", "", url])
  }
  match board_run_opener("xdg-open", [url]) {
    Ok(_) => Ok(())
    Err(linux_error) =>
      match board_run_opener("open", [url]) {
        Ok(_) => Ok(())
        Err(mac_error) =>
          Err(linux_error + "; fallback failed: " + mac_error)
      }
  }
}

///|
pub fn default_board_runtime(event_buffer : Int) -> BoardRuntime {
  let server = NativeBoardWebServer::NativeBoardWebServer()
  let opener = NativeBrowserOpener::NativeBrowserOpener()
  BoardRuntime::with_adapters(event_buffer~, server=server, opener=opener)
}

///|
pub extend NativeBoardWebServer with BoardWebServer::{
  bind,
  run,
  browser_url,
  close,
  is_alive,
  last_error,
}

///|
pub extend NativeBrowserOpener with BrowserOpener::{open}
