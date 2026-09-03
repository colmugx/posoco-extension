///|
/// callback_server.native.mbt — CallbackServer via @http.Server (native target).

///|
pub(all) struct NativeCallbackServer {
  mut code : String
  mut server : @http.Server?
}

///|
pub fn NativeCallbackServer::NativeCallbackServer() -> NativeCallbackServer {
  { code: "", server: None, }
}

///|
/// The CallbackServer impls are target-specific pub API for
/// `run_pkce_browser_flow`, which no in-workspace product calls yet; the
/// compiler's unused-impl analysis only sees dispatch through `&CallbackServer`
/// and flags `start`, so silence just that diagnostic here.
#warnings("-unused_value")
impl CallbackServer for NativeCallbackServer with fn start(
  self : NativeCallbackServer,
  port : Int,
) -> Unit raise OAuthError {
  let addr = @socket.Addr::resolve("127.0.0.1", port~) catch {
    err => raise OAuthError::HttpError("resolve: " + err.to_string())
  }
  let srv = @http.Server(addr) catch {
    err => raise OAuthError::HttpError("server bind: " + err.to_string())
  }
  self.server = Some(srv)
  // No background accept loop — wait_code polls accept directly for the
  // single callback.
}

///|
impl CallbackServer for NativeCallbackServer with fn wait_code(
  self : NativeCallbackServer,
) -> String raise OAuthError {
  let deadline = (@async.now() / 1000L).to_int() + 300 // 5 min
  match self.server {
    Some(srv) => {
      while true {
        let now = (@async.now() / 1000L).to_int()
        if now >= deadline {
          raise OAuthError::ExpiredToken
        }
        let (conn, _) = srv.accept() catch {
          _ => {
            @async.sleep(1) catch {
              _ => ()
            }
            continue
          }
        }
        let request = conn.read_request() catch {
          _ => {
            conn.close()
            continue
          }
        }
        let path = request.path
        let code = extract_code_from_path(path)
        match code {
          Some(_) => {
            conn.send_response(200, "Login successful. You can close this tab.") catch {
              _ => ()
            }
            conn.end_response() catch {
              _ => ()
            }
            conn.close()
            return match code {
              Some(c) => c
              None => ""
            }
          }
          None => {
            conn.send_response(404, "Not Found") catch {
              _ => ()
            }
            conn.end_response() catch {
              _ => ()
            }
            conn.close()
            continue
          }
        }
      }
      abort("unreachable")
    }
    None => raise OAuthError::HttpError("server not started")
  }
}

///|
impl CallbackServer for NativeCallbackServer with fn stop(
  self : NativeCallbackServer,
) -> Unit {
  match self.server {
    Some(s) => s.close()
    None => ()
  }
}

///|
/// Extract `code` query param from path like `/auth/callback?code=XXX`.
fn extract_code_from_path(path : String) -> String? {
  match path.find("?") {
    None => None
    Some(qmark) => {
      let query = path.sub(start=qmark + 1)
      match query.find("code=") {
        None => None
        Some(code_pos) => {
          let after_code = query.sub(start=code_pos + 5)
          // Code ends at & or end of string.
          match after_code.find("&") {
            Some(amp) => Some(after_code.sub(end=amp).to_owned())
            None => Some(after_code.to_owned())
          }
        }
      }
    }
  }
}

///|
/// Factory: create a native CallbackServer.
pub fn create_callback_server() -> NativeCallbackServer {
  NativeCallbackServer::NativeCallbackServer()
}
