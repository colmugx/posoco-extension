///|
/// Blackbox tests for the OpenRouter SSE processor.
///
/// Fixtures are raw SSE text ("data: {...}\n\n" lines) split the same way the
/// stage-5 chat driver will split them, then fed payload-by-payload to
/// `process_openrouter_sse`. Coverage follows the design file's six required
/// streams: normal text, pure reasoning (string + reasoning_details), tool
/// calls stitched across deltas, a mid-stream error object, a usage-only
/// trailing chunk followed by [DONE], and heartbeat comment payloads.

///|
fn feed_sse(
  raw : String,
) -> (Bool, OpenRouterStreamState, Array[@posoco.StreamChunk]) raise @posoco.ModelError {
  let state = OpenRouterStreamState()
  let chunks : Array[@posoco.StreamChunk] = []
  let on_chunk = fn(chunk : @posoco.StreamChunk) -> Unit { chunks.push(chunk) }
  let mut done = false
  // The driver forwards only "data:"-prefixed lines; replicate that split so
  // the fixture text is exactly what the wire would carry.
  for line in raw.split("\n") {
    let line = line.trim()
    if line.has_prefix("data:") {
      done = process_openrouter_sse(line[5:].trim().to_owned(), state, on_chunk)
    }
  }
  (done, state, chunks)
}

///|
test "normal text stream accumulates content and finishes on [DONE]" {
  let raw =
    #|data: {"choices":[{"delta":{"role":"assistant","content":"he"},"finish_reason":null}]}
    #|
    #|data: {"choices":[{"delta":{"content":"llo"},"finish_reason":null}]}
    #|
    #|data: {"choices":[{"delta":{},"finish_reason":"stop"}]}
    #|
    #|data: [DONE]
    #|
  let (done, state, chunks) = feed_sse(raw)
  assert_true(done)
  // 2 text deltas + 1 finish_reason=stop chunk; the trailing [DONE] emits
  // nothing because a finish_reason chunk already terminated the stream
  // semantically (OpenRouter trails usage/comment lines after it, so drivers
  // drain to [DONE]).
  assert_eq(chunks.length(), 3)
  let completion = state.to_completion()
  match completion.message.content[0] {
    Text(t) => assert_eq(t, "hello")
    _ => fail("expected concatenated text content")
  }
  assert_eq(completion.message.finish_reason, @posoco.FinishReason::Stop)
  assert_true(completion.message.reasoning is None)
}

///|
test "pure reasoning stream accumulates reasoning and reasoning_details verbatim" {
  let raw =
    #|data: {"choices":[{"delta":{"reasoning":"step one "},"finish_reason":null}]}
    #|
    #|data: {"choices":[{"delta":{"reasoning":"step two","reasoning_details":[{"type":"reasoning.text","text":"step one "}]},"finish_reason":null}]}
    #|
    #|data: {"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.encrypted","data":"QUJD"}]},"finish_reason":null}]}
    #|
    #|data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
    #|
    #|data: [DONE]
    #|
  let (done, state, chunks) = feed_sse(raw)
  assert_true(done)
  // 2 reasoning deltas + 1 usage chunk + 1 [DONE] Finish;
  // details fragments emit no chunks.
  assert_eq(chunks.length(), 4)
  let completion = state.to_completion()
  match completion.message.reasoning {
    Some(r) => {
      assert_eq(r.content, "step one step two")
      guard r.raw is Some(raw) else { fail("expected raw reasoning_details") }
      match raw {
        Array(items) => {
          // Fragments appended in arrival order, elements untouched.
          assert_true(items.length() == 2)
          assert_eq(
            items[0].stringify(),
            "{\"type\":\"reasoning.text\",\"text\":\"step one \"}",
          )
          assert_eq(
            items[1].stringify(),
            "{\"type\":\"reasoning.encrypted\",\"data\":\"QUJD\"}",
          )
        }
        _ => fail("raw must stay a JSON array")
      }
    }
    None => fail("expected reasoning with content and raw")
  }
  match completion.usage {
    Some(u) => {
      assert_eq(u.input_tokens, Some(10))
      assert_eq(u.output_tokens, Some(5))
    }
    None => fail("expected auto-attached usage")
  }
}

///|
/// reasoning_details fragments without any `reasoning` string increments:
/// raw replays, content degrades to "" (same trade as the non-streaming
/// decoder — stitching display text risks reordering encrypted blocks).
test "details-only reasoning keeps empty content" {
  let raw =
    #|data: {"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.encrypted","data":"QUJD"}]},"finish_reason":null}]}
    #|
    #|data: {"choices":[{"delta":{},"finish_reason":"stop"}]}
    #|
  let (_, state, _) = feed_sse(raw)
  let completion = state.to_completion()
  match completion.message.reasoning {
    Some(r) => {
      assert_eq(r.content, "")
      match r.raw {
        Some(Array(items)) => assert_true(items.length() == 1)
        _ => fail("expected the details array on raw")
      }
    }
    None => fail("details-only reasoning must still surface a Reasoning")
  }
}

///|
test "tool call stitches across deltas and finish_reason=tool_calls wins" {
  let raw =
    #|data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_9","type":"function","function":{"name":"echo","arguments":""}}]},"finish_reason":null}]}
    #|
    #|data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":null,"function":{"name":null,"arguments":"{\"msg\":"}}]},"finish_reason":null}]}
    #|
    #|data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":null,"function":{"name":null,"arguments":"\"hi\"}"}}]},"finish_reason":null}]}
    #|
    #|data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}
    #|
    #|data: [DONE]
    #|
  let (_, state, chunks) = feed_sse(raw)
  // 3 tool-call deltas + 1 finish_reason=tool_calls chunk; the trailing
  // [DONE] emits nothing and must not clobber the recorded reason back to
  // stop (drivers drain to [DONE] past the finish chunk).
  assert_eq(chunks.length(), 4)
  let completion = state.to_completion()
  assert_eq(completion.message.finish_reason, @posoco.FinishReason::ToolCalls)
  assert_eq(completion.message.tool_calls.length(), 1)
  let tc = completion.message.tool_calls[0]
  assert_eq(tc.call_id.to_string(), "call_9")
  assert_eq(tc.name.to_string(), "echo")
  assert_eq(tc.arguments.stringify(), "{\"msg\":\"hi\"}")
}

///|
test "mid-stream error object raises Transport with bounded error_type" {
  let raw =
    #|data: {"choices":[{"delta":{"content":"par"},"finish_reason":null}]}
    #|
    #|data: {"error":{"code":429,"message":"Rate limit exceeded: free-models-per-day","metadata":{"error_type":"rate_limit_exceeded"}}}
    #|
  let result = Ok(feed_sse(raw)) catch { err => Err(err) }
  match result {
    Err(@posoco.ModelError::Transport(msg)) => {
      assert_true(msg.contains("openrouter SSE stream failure"))
      assert_true(msg.contains("stage=error"))
      assert_true(msg.contains("category=provider_error"))
      // The stable vocabulary label crosses into the message...
      assert_true(msg.contains("error_type=rate_limit_exceeded"))
      // ...free-text fields never do (error transparency).
      assert_true(!msg.contains("Rate limit exceeded"))
    }
    _ => fail("expected Transport provider_error from mid-stream error chunk")
  }
  // An error object with no metadata still raises, just without a label.
  let state = OpenRouterStreamState()
  let bare = Ok(
    process_openrouter_sse("{\"error\":{\"message\":\"boom\"}}", state, fn(_) {
      ()
    }),
  ) catch {
    err => Err(err)
  }
  match bare {
    Err(@posoco.ModelError::Transport(msg)) =>
      assert_true(!msg.contains("error_type="))
    _ => fail("expected bare Transport provider_error")
  }
}

///|
test "usage-only chunk then [DONE]: usage extracted, stream stays open" {
  // The final auto-attached usage chunk has an empty choices array and must
  // not terminate the stream — only [DONE] does.
  let raw =
    #|data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":40,"total_tokens":140,"prompt_tokens_details":{"cached_tokens":64},"prompt_cache_miss_tokens":36}}
    #|
    #|data: [DONE]
    #|
  let (done, state, chunks) = feed_sse(raw)
  assert_eq(chunks.length(), 2)
  match chunks[0] {
    Usage(..) => ()
    _ => fail("first chunk must be Usage, not Finish")
  }
  assert_true(done)
  let completion = state.to_completion()
  match completion.usage {
    Some(u) => {
      assert_eq(u.input_tokens, Some(100))
      assert_eq(u.output_tokens, Some(40))
      assert_eq(u.total_tokens, Some(140))
      // Both kit cache spellings resolve through the helpers.
      assert_eq(u.cached_input_tokens, Some(64))
      assert_eq(u.uncached_input_tokens, Some(36))
    }
    None => fail("expected usage from the usage-only chunk")
  }
}

///|
/// Heartbeat comment lines (`: OPENROUTER PROCESSING`) are filtered by the
/// driver loop's `has_prefix("data:")` check before any payload reaches this
/// processor. The ":"-prefix guard here is defense-in-depth: if a stray
/// comment ever slips through it carries no stream bytes and must be skipped,
/// never parsed (a JSON parse of ": OPENROUTER PROCESSING" would be a loud
/// failure for a perfectly healthy stream).
test "comment-line payload reaching the processor is ignored" {
  let state = OpenRouterStreamState()
  let chunks : Array[@posoco.StreamChunk] = []
  assert_false(
    process_openrouter_sse(": OPENROUTER PROCESSING", state, fn(c) {
      chunks.push(c)
    }),
  )
  assert_eq(chunks.length(), 0)
}

///|
test "loud failures keep their stage labels" {
  let cases : Array[(String, String)] = [
    ("not json", "stage=json"),
    ("[]", "stage=event, category=not_object"),
    ("{\"choices\":{}}", "stage=choices, category=wrong_type"),
    ("{\"error\":\"boom\"}", "stage=error, category=wrong_type"),
    ("{\"choices\":[[]]}", "stage=choice, category=not_object"),
    ("{\"usage\":42}", "stage=usage, category=wrong_type"),
    ("{\"choices\":[],\"usage\":\"x\"}", "stage=usage, category=wrong_type"),
    (
      "{\"choices\":[{\"delta\":{},\"finish_reason\":\"\"}]}", "stage=finish_reason, category=empty",
    ),
    (
      "{\"choices\":[{\"delta\":{\"content\":42},\"finish_reason\":null}]}", "stage=delta.content, category=wrong_type",
    ),
    (
      "{\"choices\":[{\"delta\":{\"reasoning\":42},\"finish_reason\":null}]}", "stage=delta.reasoning, category=wrong_type",
    ),
    (
      "{\"choices\":[{\"delta\":{\"reasoning_details\":\"nope\"},\"finish_reason\":null}]}",
      "stage=delta.reasoning_details, category=wrong_type",
    ),
    (
      "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":-1,\"function\":{\"name\":\"x\"}}]},\"finish_reason\":null}]}",
      "stage=tool.index, category=negative",
    ),
    (
      "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"name\":\"x\"}}]},\"finish_reason\":null}]}",
      "stage=tool.index, category=missing",
    ),
    (
      "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c\"}]},\"finish_reason\":null}]}",
      "stage=tool.function, category=missing",
    ),
  ]
  for case in cases {
    let (payload, expected) = case
    let state = OpenRouterStreamState()
    let result = Ok(process_openrouter_sse(payload, state, fn(_) { () })) catch {
      err => Err(err)
    }
    match result {
      Err(err) => assert_true(err.to_string().contains(expected))
      Ok(_) => fail("expected failure for \{payload}")
    }
  }
}

///|
/// Some models attach `content: ""` to every reasoning chunk. Emitting those
/// empty strings as text deltas makes the host close the live thinking block
/// after each reasoning fragment — the "one 💭 per fragment" bug — so empty
/// deltas must be skipped entirely.
test "sse skips empty-string content and reasoning deltas" {
  let state = OpenRouterStreamState()
  let chunks : Array[@posoco.StreamChunk] = []
  fn feed(payload : String) -> Unit raise {
    let done = process_openrouter_sse(payload, state, fn(c) { chunks.push(c) })
    ignore(done)
  }
  feed(
    "{\"choices\":[{\"delta\":{\"content\":\"\",\"reasoning\":\"Let me \"}}]}",
  )
  feed(
    "{\"choices\":[{\"delta\":{\"content\":\"\",\"reasoning\":\"start.\"}}]}",
  )
  feed(
    "{\"choices\":[{\"delta\":{\"content\":\"Answer\",\"reasoning\":\"\"},\"finish_reason\":\"stop\"}]}",
  )
  feed("[DONE]")
  let completion = state.to_completion()
  // No empty text delta may exist: reasoning arrives as two merged deltas,
  // the finish chunk's trailing text as one, then the terminal marker.
  assert_eq(chunks.length(), 4)
  guard chunks[0] is ReasoningDelta(token~) else {
    fail("first chunk must be reasoning")
  }
  assert_eq(token, "Let me ")
  guard chunks[1] is ReasoningDelta(token~) else {
    fail("second chunk must be reasoning")
  }
  assert_eq(token, "start.")
  guard chunks[2] is TextDelta(token~) else {
    fail("third chunk must be the finish chunk's trailing text")
  }
  assert_eq(token, "Answer")
  guard chunks[3] is Finish(reason~) else {
    fail("fourth chunk must be the finish marker")
  }
  assert_eq(reason, "stop")
  match completion.message.reasoning {
    Some(r) => assert_eq(r.content, "Let me start.")
    None => fail("reasoning must accumulate across fragments")
  }
}
