///|
/// models_native_js.mbt — live `/models` fetch via moonbitlang/async/http.
///
/// Compiled on native and js only: `@http` is unavailable on wasm/wasm-gc.
/// The pure decoder (`parse_zen_models`) and `ZenModelInfo` type live in the
/// target-agnostic `models.mbt` and remain visible on every backend. On wasm,
/// `fetch_zen_models` is absent and `OpenCodeZenProvider::refresh` (which calls
/// it) is `#cfg`-guarded to native+js — so a wasm consumer sees the type and
/// the static catalog path but never reaches the HTTP fetch.

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
