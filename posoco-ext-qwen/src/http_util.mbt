///|
fn is_qwen_http_success(status : Int) -> Bool {
  status >= 200 && status < 300
}

///|
async fn read_qwen_error_body(client : @http.Client) -> String? {
  let data = client.read_all() catch { _ => return None }
  data.text() catch { _ => return None }
}

///|
fn classify_qwen_http_error(
  stage : String,
  status : Int,
  body_text : String,
  now_ms~ : Int64,
) -> @posoco.ModelError? {
  if is_qwen_http_success(status) {
    return None
  }
  if status == 429 {
    return @chatkit.classify_chat_completions_http_error(
      status,
      body_text,
      now_ms~,
    )
  }
  Some(
    @posoco.ModelError::Transport(
      "qwen HTTP error (stage=\{stage}, status=\{status}, body_chars=\{body_text.length()})",
    ),
  )
}

///|
fn validate_qwen_stream_tool_calls(
  acc : @posoco.StreamAccumulator,
) -> Unit raise @posoco.ModelError {
  let _ = acc.to_completion() catch {
    @posoco.ModelError::ResponseParse(message) =>
      raise @posoco.ModelError::ResponseParse(
        "qwen SSE parse failure (stage=tool_calls): " + message,
      )
    error => raise error
  }
}
