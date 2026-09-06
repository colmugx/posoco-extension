///|
/// callback_server.js.mbt — CallbackServer via Bun.serve (js target).
///
/// Bun.serve returns a server with .stop(). The fetch handler extracts
/// the `code` and `state` query params from the redirect URL.

///|
/// Bun's opaque server handle.
#external
pub type BunServer

///|
/// Start a Bun HTTP server on localhost:port. When a request arrives with
/// a `code` query param, it is written into the server struct's `code`/
/// `state` fields via a MoonBit callback bridge.
extern "js" fn bun_serve(
  port : Int,
  server_obj : JsCallbackServer,
) -> BunServer =
  #| (port, serverObj) => Bun.serve({
  #|   port: port,
  #|   fetch(req) {
  #|     const url = new URL(req.url);
  #|     const code = url.searchParams.get("code");
  #|     if (code) {
  #|       serverObj.code = code;
  #|       serverObj.state = url.searchParams.get("state") ?? "";
  #|       return new Response(
  #|         "<html><body><h2>Login successful</h2><p>You can close this tab.</p></body></html>",
  #|         { headers: { "Content-Type": "text/html" } }
  #|       );
  #|     }
  #|     const error = url.searchParams.get("error");
  #|     if (error) {
  #|       return new Response("Login failed: " + error, { status: 400 });
  #|     }
  #|     return new Response("Not found", { status: 404 });
  #|   }
  #| })

///|
extern "js" fn BunServer::stop(self : BunServer) -> Unit =
  #| (server) => server.stop()

///|
/// JS-target callback server. The `code`/`state` fields are written by the
/// Bun.serve fetch handler (directly mutated from JS via extern).
pub(all) struct JsCallbackServer {
  mut code : String
  mut state : String
  mut bun_server : BunServer?
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
  let srv = bun_serve(port, self)
  self.bun_server = Some(srv)
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
    @async.sleep(1) catch {
      _ => ()
    }
  }
  abort("unreachable")
}

///|
pub impl CallbackServer for JsCallbackServer with fn stop(
  self : JsCallbackServer,
) -> Unit {
  match self.bun_server {
    Some(s) => {
      BunServer::stop(s)
      self.bun_server = None
    }
    None => ()
  }
}

///|
/// Factory: create a js CallbackServer.
pub fn create_callback_server() -> JsCallbackServer {
  { code: "", state: "", bun_server: None, }
}
