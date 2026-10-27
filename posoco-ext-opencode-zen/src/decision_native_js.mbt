///|
/// OpenCode Zen Jev decision transport: one authenticated POST to the
/// gateway's System One endpoint. Native+wasm+js only: `@http` is
/// unavailable on wasm-gc. The codec and error classes live in decision.mbt.

///|
#cfg(any(target="native", target="wasm", target="js"))
fn OpenCodeZenDecisionPort::decision_headers(
  self : OpenCodeZenDecisionPort,
  session_id : String,
) -> @http.Headers {
  let headers : @http.Headers = {
    "Authorization": "Bearer \{self.config.api_key}",
    "Accept": "application/json",
    "Content-Type": "application/json",
  }
  for key, value in opencode_request_headers(self.config.client_id, session_id) {
    headers[@http.CaseInsensitiveString(key)] = value
  }
  for key, value in self.config.extra_headers {
    headers[@http.CaseInsensitiveString(key)] = value
  }
  headers
}

///|
#cfg(any(target="native", target="wasm", target="js"))
async fn OpenCodeZenDecisionPort::post_systemone(
  self : OpenCodeZenDecisionPort,
  request : @posoco.DecisionRequest,
  timeout_ms : Int32,
  session_id : String,
) -> Json raise @posoco.DecisionError {
  let model = self.config.model
  let body = systemone_request_json(request, model)
  let (response, body_data) = @async.with_timeout(timeout_ms, () => {
    @http.post(
      self.decision_url(),
      body.stringify(),
      headers=self.decision_headers(session_id),
    )
  }) catch {
    @async.TimeoutError => raise @posoco.DecisionError::TimedOut(timeout_ms~)
    err =>
      raise @posoco.DecisionError::Transport(
        "decision transport failure (provider=opencode model=\{model}): \{err.to_string()}",
      )
  }
  if response.code < 200 || response.code >= 300 {
    let body_bytes = body_data.binary().length()
    let error_text = body_data.text() catch { _ => "" }
    raise systemone_http_error(
      "opencode",
      model,
      response.code,
      body_bytes,
      body=if error_text.length() > 0 { Some(error_text) } else { None },
    )
  }
  let body_text = body_data.text() catch {
    _ =>
      raise @posoco.DecisionError::ResponseParse(
        "decision response body is not valid UTF-8 (provider=opencode model=\{model}, body_bytes=\{body_data.binary().length()})",
      )
  }
  @json.parse(body_text) catch {
    _ =>
      raise @posoco.DecisionError::ResponseParse(
        "decision response body is not valid JSON (provider=opencode model=\{model})",
      )
  }
}

///|
/// The session fact is explicit only: a contextual call routes under the
/// caller's session, a bare call mints a fresh per-request session id (the
/// gateway uses it for request routing, never identity). Nothing is cached
/// at process or provider scope.
#cfg(any(target="native", target="wasm", target="js"))
fn OpenCodeZenDecisionPort::session_for(
  self : OpenCodeZenDecisionPort,
  context~ : @posoco.DecisionCallContext,
) -> String {
  match context.scope {
    Some(scope) if scope.session.length() > 0 => scope.session
    _ => opencode_session_uuid()
  }
}

///|
#cfg(any(target="native", target="wasm", target="js"))
pub impl @posoco.DecisionPort for OpenCodeZenDecisionPort with fn evaluate(
  self : OpenCodeZenDecisionPort,
  request : @posoco.DecisionRequest,
  context~ : @posoco.DecisionCallContext,
) -> @posoco.DecisionResult raise @posoco.DecisionError {
  let payload = self.post_systemone(
    request,
    self.timeout_ms(context~),
    self.session_for(context~),
  )
  systemone_parse_response(payload, request)
}

///|
#cfg(any(target="native", target="wasm", target="js"))
pub extend OpenCodeZenDecisionPort with @posoco.DecisionPort::{evaluate}
