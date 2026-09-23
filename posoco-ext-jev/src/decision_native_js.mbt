///|
/// Hosted TypeSafe Jev DecisionPort implementation for native, wasm, and js.

///|
fn jev_url(config : JevConfig) -> String {
  let base = match config.base_url.strip_suffix("/") {
    Some(value) => value.to_owned()
    None => config.base_url
  }
  base + "/v1/systemone"
}

///|
fn jev_headers(api_key : String) -> @http.Headers {
  {
    "Authorization": "Bearer " + api_key,
    "Accept": "application/json",
    "Content-Type": "application/json",
  }
}

///|
fn jev_http_error(
  status : Int,
  body_bytes : Int,
) -> @posoco.DecisionError {
  if status == 429 {
    @posoco.DecisionError::RateLimited({
      message: "TypeSafe Jev rate limited",
      reset_at_ms: None,
      provider_code: None,
    })
  } else if status == 400 {
    @posoco.DecisionError::RequestBuild(
      "TypeSafe Jev rejected the decision request (HTTP 400, body_bytes=" +
      body_bytes.to_string() +
      ")",
    )
  } else {
    @posoco.DecisionError::Transport(
      "TypeSafe Jev HTTP status=" +
      status.to_string() +
      ", body_bytes=" +
      body_bytes.to_string(),
    )
  }
}

///|
pub impl @posoco.DecisionPort for JevDecisionPort with fn evaluate(
  self : JevDecisionPort,
  request : @posoco.DecisionRequest,
) -> @posoco.DecisionResult raise @posoco.DecisionError {
  let api_key = self.resolve_api_key()
  let body = build_jev_request(request, self.config.model)
  let (response, body_data) = @async.with_timeout(self.config.timeout_ms, () => {
    @http.post(jev_url(self.config), body.stringify(), headers=jev_headers(api_key))
  }) catch {
    @async.TimeoutError =>
      raise @posoco.DecisionError::Transport(
        "TypeSafe Jev request timed out (timeout_ms=" +
        self.config.timeout_ms.to_string() +
        ")",
      )
    err =>
      raise @posoco.DecisionError::Transport(
        "TypeSafe Jev request failed: " + err.to_string(),
      )
  }
  if response.code < 200 || response.code >= 300 {
    raise jev_http_error(response.code, body_data.binary().length())
  }
  let body_text = body_data.text() catch {
    _ =>
      raise @posoco.DecisionError::ResponseParse(
        "TypeSafe Jev response body is not valid UTF-8",
      )
  }
  let payload : Json = @json.parse(body_text) catch {
    _ =>
      raise @posoco.DecisionError::ResponseParse(
        "TypeSafe Jev response body is not valid JSON",
      )
  }
  decode_jev_response(payload, request)
}
