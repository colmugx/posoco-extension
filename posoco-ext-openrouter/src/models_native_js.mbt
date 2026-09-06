///|
/// Live `GET /models` fetch via moonbitlang/async/http. Compiled on native
/// and js only: `@http` is unavailable on wasm/wasm-gc.

///|
/// Fetch and decode the live OpenRouter model catalog. The listing is
/// publicly readable today, but the key is still sent so the request keeps
/// working unchanged if OpenRouter later gates discovery behind auth.
pub async fn fetch_openrouter_models(
  base_url : String,
  api_key : String,
) -> Array[OpenRouterModelInfo] raise @posoco.ModelError {
  let clean = match base_url.strip_suffix("/") {
    Some(value) => value.to_owned()
    None => base_url
  }
  let headers : @http.Headers = {
    "Authorization": "Bearer " + api_key,
    "Accept": "application/json",
  }
  let (response, body_data) = @async.with_timeout(30000, () => {
    @http.get(clean + "/models", headers~)
  }) catch {
    @async.TimeoutError =>
      raise @posoco.ModelError::Transport(
        "OpenRouter list models request timed out (timeout_ms=30000)",
      )
    err =>
      raise @posoco.ModelError::Transport(
        "OpenRouter list models request failed: " + err.to_string(),
      )
  }
  if response.code < 200 || response.code >= 300 {
    let byte_length = body_data.binary().length()
    let text = body_data.text() catch {
      _ =>
        raise @posoco.ModelError::Transport(
          "OpenRouter list models HTTP status: \{response.code}, body_bytes=\{byte_length}, body_category=invalid_utf8",
        )
    }
    raise @posoco.ModelError::Transport(
      "OpenRouter list models HTTP status: \{response.code}, body=\{text}",
    )
  }
  let body_text = body_data.text() catch {
    err =>
      raise @posoco.ModelError::Transport(
        "OpenRouter list models body read failed: " + err.to_string(),
      )
  }
  let payload = @json.parse(body_text) catch {
    err =>
      raise @posoco.ModelError::ResponseParse(
        "OpenRouter list models JSON parse failed: " + err.to_string(),
      )
  }
  parse_openrouter_models(payload)
}
