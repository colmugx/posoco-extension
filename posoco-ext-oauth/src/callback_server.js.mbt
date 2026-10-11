///|
/// CallbackServer via node:http (#module injection). MoonBit structs are plain JS
/// objects on this backend, so the request handler mutates fields directly.

///|
/// Opaque node:http server handle.
#external
pub type NodeServer

///|
/// Value-passing shape for the request handler built inside the wrapper.
#external
priv type NodeHttpHandler

///|
#module("node:http")
extern "js" fn http_create_server(handler : NodeHttpHandler) -> NodeServer = "createServer"

///|
/// Start a localhost HTTP server on `port`; a request carrying a `code` query param
/// is written straight into the server struct's `code`/`state` fields (plain JS objects).
extern "js" fn node_serve(
  create_server : (NodeHttpHandler) -> NodeServer,
  port : Int,
  server_obj : JsCallbackServer,
) -> NodeServer =
  #| (createServer, port, serverObj) => {
  #|   const server = createServer((req, res) => {
  #|     const url = new URL(req.url ?? "/", "http://localhost:" + port);
  #|     const code = url.searchParams.get("code");
  #|     if (code) {
  #|       serverObj.code = code;
  #|       serverObj.state = url.searchParams.get("state") ?? "";
  #|       res.writeHead(200, { "Content-Type": "text/html" });
  #|       res.end("<html><body><h2>Login successful</h2><p>You can close this tab.</p></body></html>");
  #|       return;
  #|     }
  #|     const error = url.searchParams.get("error");
  #|     if (error) {
  #|       res.writeHead(400, { "Content-Type": "text/plain" });
  #|       res.end("Login failed: " + error);
  #|       return;
  #|     }
  #|     res.writeHead(404, { "Content-Type": "text/plain" });
  #|     res.end("Not found");
  #|   });
  #|   server.listen(port);
  #|   return server;
  #| }

///|
extern "js" fn NodeServer::stop(self : NodeServer) -> Unit =
  #| (server) => { try { server.close() } catch {} }

///|
/// The `code`/`state` fields are written directly by the node:http request handler.
pub(all) struct JsCallbackServer {
  mut code : String
  mut state : String
  mut node_server : NodeServer?
}

///|
/// See callback_server.native.mbt: the impl is pub API for
/// `run_pkce_browser_flow`; only `&CallbackServer` dispatch exists in-workspace
/// and the compiler flags `start`, so silence just that diagnostic here.
#warnings("-unused_value")
pub impl CallbackServer for JsCallbackServer with fn start(
  self : JsCallbackServer,
  port : Int,
) -> Unit raise OAuthError {
  let srv = node_serve(http_create_server, port, self)
  self.node_server = Some(srv)
}

///|
pub impl CallbackServer for JsCallbackServer with fn wait_callback(
  self : JsCallbackServer,
) -> (String, String) raise OAuthError {
  let deadline = (@async.now() / 1000L).to_int() + 300 // 5 min
  while true {
    if self.code.length() > 0 {
      return (self.code, self.state)
    }
    let now = (@async.now() / 1000L).to_int()
    if now >= deadline {
      raise OAuthError::ExpiredToken
    }
    @async.sleep(1)
  }
  abort("unreachable")
}

///|
pub impl CallbackServer for JsCallbackServer with fn stop(
  self : JsCallbackServer,
) -> Unit {
  match self.node_server {
    Some(s) => {
      NodeServer::stop(s)
      self.node_server = None
    }
    None => ()
  }
}

///|
pub fn create_callback_server() -> JsCallbackServer {
  { code: "", state: "", node_server: None, }
}

///|
pub extend JsCallbackServer with CallbackServer::{start, stop, wait_callback}
