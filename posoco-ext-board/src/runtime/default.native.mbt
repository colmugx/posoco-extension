///|
pub struct NativeBoardWebServer {
  hub : BoardEventHub
  connections : Array[@async.Task[Unit]]
  mut server : @http.Server?
  mut endpoint : BoardEndpoint?
  mut token : String?
  mut alive : Bool
  mut closing : Bool
  mut error : String?
}

///|
pub fn NativeBoardWebServer::NativeBoardWebServer(
  hub? : BoardEventHub = BoardEventHub(),
) -> NativeBoardWebServer {
  {
    hub,
    connections: [],
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
  conn.send_response(code, reason, extra_headers={
    "Content-Type": content_type,
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  })
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
fn board_request_token_ok(request : @http.Request, token : String) -> Bool {
  board_query_param(request.path, "token") == Some(token)
}

///|
fn board_placeholder_page() -> String {
  let page =
    #|<!doctype html><html><head><meta charset="utf-8"><title>Posoco Board diagnostics</title></head>
    #|<body><main><h1>Board diagnostics</h1><p id="status">connecting</p><pre id="events"></pre></main>
    #|<script>(()=>{
    #|const status=document.getElementById('status'), output=document.getElementById('events');
    #|const token=new URLSearchParams(location.search).get('token');
    #|if(!token){status.textContent='missing bootstrap token';return;}
    #|const key='board.cursor.'+location.host, valid=n=>Number.isSafeInteger(n)&&n>=0;
    #|let seq=0, lines=[], socket=null, timer=null, stopped=false, suspended=false, delay=250;
    #|try{const saved=Number(sessionStorage.getItem(key));if(valid(saved))seq=saved;}catch(_){}
    #|const cursor=n=>{seq=n;try{sessionStorage.setItem(key,String(n));}catch(_){}};
    #|const show=s=>{status.textContent=s+' | seq '+seq;};
    #|const line=e=>('seq '+e.seq+' | kind '+String(e.kind)+' | scope '+JSON.stringify(e.scope??null)).slice(0,512);
    #|const render=()=>{output.textContent=lines.join('\n');};
    #|const reset=(ws,s)=>{cursor(0);lines=[];render();show(s);ws.close();};
    #|function connect(){
    #|  timer=null;if(stopped||suspended||socket!==null)return;
    #|  const ws=new WebSocket('ws://'+location.host+'/ws?token='+encodeURIComponent(token));socket=ws;
    #|  ws.onopen=()=>{if(socket!==ws||stopped||suspended)return;ws.send(JSON.stringify({type:'hello',protocol_version:1,last_seq:seq}));show('connected; hello sent');};
    #|  ws.onmessage=ev=>{
    #|    if(socket!==ws||ws.readyState!==WebSocket.OPEN||stopped||suspended)return;
    #|    try{
    #|      const f=JSON.parse(ev.data);
    #|      if(f.type==='resync_required'){reset(ws,'resync required');return;}
    #|      if(f.type==='error'){show('protocol error: '+String(f.code).slice(0,80));stopped=true;ws.close();return;}
    #|      if(f.type==='snapshot'){
    #|        if(f.protocol_version!==1||!valid(f.last_seq)||!Array.isArray(f.payload?.events))throw Error();
    #|        const events=f.payload.events, first=f.last_seq-events.length+1;
    #|        if(first<1||(events.length===0&&f.last_seq!==0))throw Error();
    #|        for(let i=0;i<events.length;i++){const e=events[i];if(e.type!=='event'||!valid(e.seq)||e.seq!==first+i)throw Error();}
    #|        lines=events.slice(-100).map(line);cursor(f.last_seq);render();show('snapshot');delay=250;
    #|      }else if(f.type==='event'){
    #|        if(!valid(f.seq))throw Error();if(f.seq<=seq)return;
    #|        if(f.seq!==seq+1){reset(ws,'sequence gap; reconnecting');return;}
    #|        cursor(f.seq);lines.push(line(f));lines=lines.slice(-100);render();show('live');delay=250;
    #|      }
    #|    }catch(_){reset(ws,'invalid frame; reconnecting');}
    #|  };
    #|  ws.onerror=()=>{if(socket===ws)show('connection error');};
    #|  ws.onclose=()=>{if(socket!==ws)return;socket=null;if(stopped)return;show('disconnected; reconnecting');if(timer===null){timer=setTimeout(connect,delay);delay=Math.min(delay*2,10000);}};
    #|}
    #|addEventListener('pagehide',()=>{suspended=true;if(timer!==null)clearTimeout(timer);timer=null;const old=socket;socket=null;if(old)old.close();});
    #|addEventListener('pageshow',e=>{if(e.persisted&&suspended){suspended=false;delay=250;connect();}});
    #|connect();
    #|})();</script></body></html>
  page
}

///|
priv suberror BoardFrameError {
  ExpectedText
  FrameTooLarge
}

///|
async fn board_read_text(ws : @websocket.Conn) -> String {
  let message = ws.recv()
  guard message.kind is Text else { raise ExpectedText }
  let bytes : Array[Byte] = []
  while message.read_some(max_len=8193 - bytes.length()) is Some(chunk) {
    for byte in chunk {
      bytes.push(byte)
    }
    if bytes.length() > 8192 {
      raise FrameTooLarge
    }
  }
  @utf8.decode(Bytes::from_array(bytes))
}

///|
async fn board_receive_hello(
  ws : @websocket.Conn,
) -> Result[@protocol.BoardHello, @protocol.BoardServerFrame] {
  let raw = @async.with_timeout(5000, () => board_read_text(ws)) catch {
    @async.TimeoutError =>
      return Err(
        @protocol.Error(
          code="hello_timeout",
          message="Hello required within 5 seconds",
        ),
      )
    ExpectedText =>
      return Err(
        @protocol.Error(code="expected_text", message="Hello must be text"),
      )
    FrameTooLarge =>
      return Err(
        @protocol.Error(
          code="frame_too_large",
          message="Client frames are limited to 8192 bytes",
        ),
      )
    error => raise error
  }
  match @protocol.decode_client_frame(raw) {
    Ok(Hello(hello)) => Ok(hello)
    Ok(Command(_)) =>
      Err(
        @protocol.Error(
          code="hello_required",
          message="First frame must be Hello",
        ),
      )
    Err(UnsupportedVersion(..)) =>
      Err(
        @protocol.Error(
          code="unsupported_version",
          message="Expected protocol version 1",
        ),
      )
    Err(_) =>
      Err(
        @protocol.Error(code="invalid_hello", message="Invalid Hello or cursor"),
      )
  }
}

///|
async fn board_write_frame(
  ws : @websocket.Conn,
  frame : @protocol.BoardServerFrame,
) -> Unit {
  @async.with_timeout(1000, () => {
    ws.send_text(@protocol.encode_server_frame(frame))
  })
}

///|
async fn board_client_sender(
  ws : @websocket.Conn,
  client : BoardSubscription,
) -> Unit {
  board_send_subscription(client, frame => board_write_frame(ws, frame))
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
      board_send(
        conn, 503, "Service Unavailable", "text/plain; charset=utf-8", "not running",
      )
      return
    }
  }
  let token = match self.token {
    Some(value) => value
    None => {
      board_send(
        conn, 503, "Service Unavailable", "text/plain; charset=utf-8", "not running",
      )
      return
    }
  }
  if !board_request_host_ok(request, endpoint) ||
    !board_request_origin_ok(request, endpoint) {
    board_send(conn, 403, "Forbidden", "text/plain; charset=utf-8", "forbidden")
    return
  }
  if !board_request_token_ok(request, token) {
    board_send(
      conn, 401, "Unauthorized", "text/plain; charset=utf-8", "unauthorized",
    )
    return
  }
  let ws = @websocket.from_http_server(request, conn)
  defer ws.close()
  if self.closing || self.token != Some(token) {
    return
  }
  @async.with_task_group(group => {
    let task = group.spawn(() => self.serve_ws(ws))
    self.connections.push(task)
    defer (for i, candidate in self.connections {
      if physical_equal(candidate, task) {
        let _ = self.connections.remove(i)
        break
      }
    })
    task.wait()
  }) catch {
    _ => ()
  }
}

///|
async fn NativeBoardWebServer::serve_ws(
  self : NativeBoardWebServer,
  ws : @websocket.Conn,
) -> Unit {
  let first = board_receive_hello(ws) catch { _ => return }
  let hello = match first {
    Ok(hello) => hello
    Err(frame) => {
      board_write_frame(ws, frame) catch {
        _ => ()
      }
      return
    }
  }
  let client = self.hub.subscribe(hello.last_seq)
  defer self.hub.unsubscribe(client)
  // any owns and joins both local tasks on success, failure and cancellation.
  @async.any([
    () => board_client_sender(ws, client),
    () => {
      for ;; {
        let raw = board_read_text(ws)
        let frame = match @protocol.decode_client_frame(raw) {
          Ok(Command(command)) =>
            @protocol.CommandResult({
              command_id: command.command_id,
              accepted: false,
              error: Some("unsupported_in_current_stage"),
              current_revision: Some(0L),
            })
          _ =>
            @protocol.Error(
              code="invalid_frame",
              message="Expected Command after Hello",
            )
        }
        client.enqueue(frame, self.hub.current_seq())
      }
    },
  ]) catch {
    _ => ()
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
      board_send(
        conn, 503, "Service Unavailable", "text/plain; charset=utf-8", "not running",
      )
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
      board_send(
        conn, 503, "Service Unavailable", "text/plain; charset=utf-8", "not running",
      )
      return
    }
  }
  if path == "/ws" {
    self.handle_ws(request, conn)
    return
  }
  if !board_request_token_ok(request, token) {
    board_send(
      conn, 401, "Unauthorized", "text/plain; charset=utf-8", "unauthorized",
    )
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
          "protocol_version": Json::number(
            @protocol.protocol_version().to_double(),
          ),
          "host": Json::string(endpoint.host),
          "port": Json::number(endpoint.port.to_double()),
          "ws_path": Json::string("/ws"),
        }).stringify(),
      )
    _ =>
      board_send(
        conn, 404, "Not Found", "text/plain; charset=utf-8", "not found",
      )
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
  for task in self.connections {
    task.cancel()
  }
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
    Err(error) =>
      Err("board: browser opener '\{command}' failed: " + error.to_string())
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
        Err(mac_error) => Err(linux_error + "; fallback failed: " + mac_error)
      }
  }
}

///|
pub fn default_board_runtime(
  event_buffer : Int,
  client_queue_depth? : Int = 256,
) -> BoardRuntime {
  let hub = BoardEventHub(capacity=event_buffer, client_queue_depth~)
  let server = NativeBoardWebServer(hub~)
  let opener = NativeBrowserOpener::NativeBrowserOpener()
  BoardRuntime::with_adapters(hub~, server~, opener~)
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
