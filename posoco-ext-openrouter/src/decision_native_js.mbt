///|
/// OpenRouter Jev decision transport: one authenticated POST to the
/// provider's System One endpoint. Native+wasm+js only: `@http` is
/// unavailable on wasm-gc. Pure wire vocabulary and error classes live in
/// decision.mbt.

///|
#cfg(any(target="native", target="wasm", target="js"))
async fn OpenRouterDecisionPort::post_systemone(
  self : OpenRouterDecisionPort,
  request : @posoco.DecisionRequest,
  timeout_ms : Int32,
) -> Json raise @posoco.DecisionError {
  let model = self.config.model
  let body = openrouter_decision_request_json(request, model)
  let (response, body_data) = @async.with_timeout(timeout_ms, () => {
    @http.post(
      self.decision_url(),
      body.stringify(),
      headers=build_headers(self.config),
    )
  }) catch {
    @async.TimeoutError => raise @posoco.DecisionError::TimedOut(timeout_ms~)
    err =>
      raise @posoco.DecisionError::Transport(
        "decision transport failure (provider=openrouter model=\{model}): \{err.to_string()}",
      )
  }
  if response.code < 200 || response.code >= 300 {
    let body_bytes = body_data.binary().length()
    let error_text = body_data.text() catch { _ => "" }
    raise openrouter_decision_http_error(
      model,
      response.code,
      body_bytes,
      body=if error_text.length() > 0 { Some(error_text) } else { None },
    )
  }
  let body_text = body_data.text() catch {
    _ =>
      raise @posoco.DecisionError::ResponseParse(
        "decision response body is not valid UTF-8 (provider=openrouter model=\{model}, body_bytes=\{body_data.binary().length()})",
      )
  }
  @json.parse(body_text) catch {
    _ =>
      raise @posoco.DecisionError::ResponseParse(
        "decision response body is not valid JSON (provider=openrouter model=\{model})",
      )
  }
}

///|
#cfg(any(target="native", target="wasm", target="js"))
pub impl @posoco.DecisionPort for OpenRouterDecisionPort with fn evaluate_with_context(
  self : OpenRouterDecisionPort,
  request : @posoco.DecisionRequest,
  context~ : @posoco.DecisionCallContext,
) -> @posoco.DecisionResult raise @posoco.DecisionError {
  let payload = self.post_systemone(request, self.timeout_ms(context~))
  openrouter_decision_response_json(payload, request)
}

///|
#cfg(any(target="native", target="wasm", target="js"))
pub impl @posoco.DecisionPort for OpenRouterDecisionPort with fn evaluate(
  self : OpenRouterDecisionPort,
  request : @posoco.DecisionRequest,
) -> @posoco.DecisionResult raise @posoco.DecisionError {
  let context = @posoco.DecisionCallContext::make(purpose="openrouter_decision")
  let payload = self.post_systemone(request, self.timeout_ms(context~))
  openrouter_decision_response_json(payload, request)
}

///|
#cfg(any(target="native", target="wasm", target="js"))
pub extend OpenRouterDecisionPort with @posoco.DecisionPort::{
  evaluate,
  evaluate_with_context,
}
