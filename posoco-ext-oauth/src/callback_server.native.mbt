///|
/// callback_server.native.mbt — CallbackServer via @http.Server (native target).

///|
pub(all) struct NativeCallbackServer {
  mut code : String
  mut server : @http.Server?
  wait_timeout_ms : Int32
}

///|
pub fn NativeCallbackServer::NativeCallbackServer(
  wait_timeout_ms~ : Int32 = 300_000,
) -> NativeCallbackServer {
  { code: "", server: None, wait_timeout_ms, }
}

///|
/// The CallbackServer impls are target-specific pub API for
/// `run_pkce_browser_flow`, which no in-workspace product calls yet; the
/// compiler's unused-impl analysis only sees dispatch through `&CallbackServer`
/// and flags `start`, so silence just that diagnostic here.
#warnings("-unused_value")
pub impl CallbackServer for NativeCallbackServer with fn start(
  self : NativeCallbackServer,
  port : Int32,
) -> Unit raise OAuthError {
  let addr = @socket.Addr::resolve("127.0.0.1", port=port.to_uint16()) catch {
    err => raise OAuthError::HttpError("resolve: " + err.to_string())
  }
  // The callback port is usually fixed by the provider's redirect URI, so a
  // login that follows a finished one must not lose the bind to connections
  // of the previous callback still lingering in TIME_WAIT.
  let srv = @http.Server(addr, reuse_addr=true) catch {
    err => raise OAuthError::HttpError("server bind: " + err.to_string())
  }
  self.server = Some(srv)
  // No background accept loop — wait_callback polls accept directly for the
  // single callback.
}

///|
pub extend NativeCallbackServer with CallbackServer::{
  start,
  stop,
  wait_callback,
}

///|
pub impl CallbackServer for NativeCallbackServer with fn wait_callback(
  self : NativeCallbackServer,
) -> (String, String) raise OAuthError {
  match self.server {
    Some(srv) => {
      let deadline_ms = @async.now() + self.wait_timeout_ms.to_int64()
      while true {
        let remaining_ms = (deadline_ms - @async.now()).to_int()
        if remaining_ms <= 0 {
          raise OAuthError::ExpiredToken
        }
        // Bound each accept so an abandoned login surfaces as ExpiredToken
        // instead of parking forever on the listener.
        let conn = @async.with_timeout(remaining_ms, () => srv.accept()) catch {
          @async.TimeoutError => raise OAuthError::ExpiredToken
          _ => {
            @async.sleep(1)
            continue
          }
        }
        let request = conn.read_request() catch {
          _ => {
            conn.close()
            continue
          }
        }
        match extract_query_param(request.path, "code") {
          Some(code) => {
            conn.send_response(200, "Login successful. You can close this tab.") catch {
              _ => ()
            }
            conn.end_response() catch {
              _ => ()
            }
            conn.close()
            // A missing state surfaces later as "oauth state mismatch".
            let state = match extract_query_param(request.path, "state") {
              Some(s) => s
              None => ""
            }
            return (code, state)
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
pub impl CallbackServer for NativeCallbackServer with fn stop(
  self : NativeCallbackServer,
) -> Unit {
  match self.server {
    Some(s) => {
      s.close()
      self.server = None
    }
    None => ()
  }
}

///|
/// Factory: create a native CallbackServer.
pub fn create_callback_server() -> NativeCallbackServer {
  NativeCallbackServer::NativeCallbackServer()
}
