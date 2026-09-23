///|
/// Live model discovery via moonbitlang/async/http: the Zen `/models`
/// listing plus the models.dev reasoning surfaces that enrich it.
///
/// Compiled on native, wasm, and js (`@http` is unavailable on wasm-gc).

///|
/// Fetch and decode the live OpenCode Zen model catalog.
///
/// The chat endpoint requires an API key (probed: `Authorization: Bearer` is
/// the scheme Zen honors). The `/models` listing is publicly readable today,
/// but the key is still sent so the request keeps working unchanged if Zen
/// later gates discovery behind auth.
pub async fn fetch_zen_models(
  base_url : String,
  api_key : String,
  endpoint_prefix? : String = "",
) -> Array[ZenModelInfo] raise @posoco.ModelError {
  let headers : @http.Headers = {
    "Authorization": "Bearer " + api_key,
    "Accept": "application/json",
  }
  let (response, body_data) = @async.with_timeout(30000, () => {
    @http.get(zen_models_url(base_url, endpoint_prefix), headers~)
  }) catch {
    @async.TimeoutError =>
      raise @posoco.ModelError::Transport(
        "OpenCode Zen list models request timed out (timeout_ms=30000)",
      )
    err =>
      raise @posoco.ModelError::Transport(
        "OpenCode Zen list models request failed: " + err.to_string(),
      )
  }
  if response.code < 200 || response.code >= 300 {
    // The gateway's error body names the failure cause; carry it verbatim.
    let byte_length = body_data.binary().length()
    let text = body_data.text() catch {
      _ =>
        raise @posoco.ModelError::Transport(
          "OpenCode Zen list models HTTP status: \{response.code}, body_bytes=\{byte_length}, body_category=invalid_utf8",
        )
    }
    raise @posoco.ModelError::Transport(
      "OpenCode Zen list models HTTP status: \{response.code}, body=\{text}",
    )
  }
  let body_text = body_data.text() catch {
    err =>
      raise @posoco.ModelError::Transport(
        "OpenCode Zen list models body read failed: " + err.to_string(),
      )
  }
  let payload = @json.parse(body_text) catch {
    err =>
      raise @posoco.ModelError::ResponseParse(
        "OpenCode Zen list models JSON parse failed: " + err.to_string(),
      )
  }
  parse_zen_models(payload)
}

///|
/// Fetch and decode the per-model reasoning surfaces from models.dev's
/// OpenCode mirror. Anonymous: the mirror is publicly readable, so no
/// credential is sent. Callers own the degradation policy — refresh swallows
/// every failure here into an empty map rather than aborting composition.
async fn fetch_models_dev_surfaces() -> Map[String, ZenReasoningSurface] raise @posoco.ModelError {
  let headers : @http.Headers = { "Accept": "application/json" }
  let (response, body_data) = @async.with_timeout(30000, () => {
    @http.get(zen_models_dev_url, headers~)
  }) catch {
    @async.TimeoutError =>
      raise @posoco.ModelError::Transport(
        "models.dev surfaces request timed out (timeout_ms=30000)",
      )
    err =>
      raise @posoco.ModelError::Transport(
        "models.dev surfaces request failed: " + err.to_string(),
      )
  }
  if response.code < 200 || response.code >= 300 {
    let byte_length = body_data.binary().length()
    let text = body_data.text() catch {
      _ =>
        raise @posoco.ModelError::Transport(
          "models.dev surfaces HTTP status: \{response.code}, body_bytes=\{byte_length}, body_category=invalid_utf8",
        )
    }
    raise @posoco.ModelError::Transport(
      "models.dev surfaces HTTP status: \{response.code}, body=\{text}",
    )
  }
  let body_text = body_data.text() catch {
    err =>
      raise @posoco.ModelError::Transport(
        "models.dev surfaces body read failed: " + err.to_string(),
      )
  }
  let payload = @json.parse(body_text) catch {
    err =>
      raise @posoco.ModelError::ResponseParse(
        "models.dev surfaces JSON parse failed: " + err.to_string(),
      )
  }
  parse_models_dev_surfaces(payload)
}
