///|
/// posoco_ext_deepseek — ModelPort implementation.
///
/// Implements @posoco.ModelPort for DeepSeek's /chat/completions endpoint.
/// DeepSeek-specific optimizations:
/// - Historical reasoning_content is never resent (structurally guaranteed
///   by posoco Message having no reasoning field — see encode.mbt).
/// - Append-only message ordering for context cache friendliness.
/// - SSE streaming via StreamAccumulator.

///|
/// Build HTTP headers for DeepSeek API requests.
fn build_headers(config : DeepSeekConfig) -> Map[String, String] {
  {
    "Authorization": "Bearer " + config.api_key,
    "Content-Type": "application/json",
  }
}

///|
/// ModelPort implementation — non-streaming chat via /chat/completions.
pub impl @posoco.ModelPort for DeepSeekModelPort with fn chat(
  self : DeepSeekModelPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
) -> @posoco.ModelResponse raise @posoco.ModelError {
  let (model, thinking) = resolve_model(self.config, options)
  let body = build_chat_request(messages, tools, options, model, thinking, false)
  let headers = build_headers(self.config)
  let client = @http.Client::Client(self.config.base_url, headers~) catch {
    e =>
      raise @posoco.ModelError::Transport("Failed to create HTTP client: \{e}")
  }
  let _ = client.post("/chat/completions", body.stringify()) catch {
    e =>
      raise @posoco.ModelError::Transport("HTTP request failed: \{e}")
  }
  let body_data = client.read_all() catch {
    e => raise @posoco.ModelError::Transport("Failed to read response: \{e}")
  }
  client.close()
  let body_text = body_data.text() catch {
    e =>
      raise @posoco.ModelError::ResponseParse("Failed to decode response: \{e}")
  }
  let resp_json : Json = try @json.parse(body_text) catch {
    e => raise @posoco.ModelError::ResponseParse("JSON parse error: \{e}")
  }
  decode_chat_response(resp_json)
}

///|
/// ModelPort implementation — streaming chat via /chat/completions with SSE.
/// Reads SSE events line by line, feeds StreamChunk to on_chunk + accumulator.
pub impl @posoco.ModelPort for DeepSeekModelPort with fn chat_streaming(
  self : DeepSeekModelPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> @posoco.ModelResponse raise @posoco.ModelError {
  let (model, thinking) = resolve_model(self.config, options)
  let body = build_chat_request(messages, tools, options, model, thinking, true)
  let headers = build_headers(self.config)
  let client = @http.Client::Client(self.config.base_url, headers~) catch {
    e =>
      raise @posoco.ModelError::Transport("Failed to create HTTP client: \{e}")
  }
  client.request(@http.RequestMethod::Post, "/chat/completions") catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport("Request send failed")
    }
  }
  client.write(body.stringify()) catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport("Write body failed")
    }
  }
  client.flush() catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport("Flush failed")
    }
  }
  let response = client.end_request() catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport("End request failed")
    }
  }
  if response.code != 200 {
    client.close()
    raise @posoco.ModelError::Transport(
      "DeepSeek API error \{response.code}",
    )
  }
  // Read SSE stream line by line
  let acc = @posoco.StreamAccumulator::new()
  let mut done = false
  let mut data_buffer = ""
  while !done {
    let line = client.read_until("\n") catch { _ => None }
    match line {
      Some(data) => {
        let trimmed = data.trim()
        if trimmed.has_prefix("data: ") {
          let payload = trimmed[6:].to_owned()
          if payload.length() > 0 {
            data_buffer = payload
            done = process_deepseek_sse(payload, acc, on_chunk)
          }
        } else if trimmed == "" && data_buffer.length() > 0 {
          // Empty line = event boundary; data already processed
          data_buffer = ""
        }
      }
      None => {
        // Stream closed
        if !(
          acc.tool_calls.length() > 0 || acc.text != "" || acc.reasoning != ""
        ) {
          client.close()
          raise @posoco.ModelError::ResponseParse(
            "Stream ended with no content",
          )
        }
        done = true
      }
    }
  }
  client.close()
  acc.to_response()
}
