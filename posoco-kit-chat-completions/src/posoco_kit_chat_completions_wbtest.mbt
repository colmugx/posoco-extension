///|
/// Regression suite for the shared chat-completions SSE parser. The three
/// delegating extensions (openai-compatible, deepseek, kimi) pin only their
/// provider-prefix wiring; all parser behavior lives here.

///|
fn run_sse(
  data : String,
) -> (Bool, @posoco.StreamAccumulator, Array[@posoco.StreamChunk]) raise @posoco.ModelError {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let chunks : Array[@posoco.StreamChunk] = []
  let on_chunk = fn(chunk : @posoco.StreamChunk) -> Unit { chunks.push(chunk) }
  let done = process_chat_completions_sse(
    provider="testprov",
    data,
    acc,
    on_chunk,
  )
  (done, acc, chunks)
}

///|
test "[DONE] finishes the stream" {
  let (done, _, chunks) = run_sse("[DONE]")
  assert_true(done)
  assert_eq(chunks.length(), 1)
}

///|
test "text and reasoning deltas accumulate" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let chunks : Array[@posoco.StreamChunk] = []
  let on_chunk = fn(chunk : @posoco.StreamChunk) -> Unit { chunks.push(chunk) }
  let d1 = process_chat_completions_sse(
    provider="testprov",
    "{\"choices\":[{\"delta\":{\"content\":\"he\",\"reasoning_content\":\"think\"},\"finish_reason\":null}]}",
    acc,
    on_chunk,
  )
  assert_false(d1)
  let d2 = process_chat_completions_sse(
    provider="testprov",
    "{\"choices\":[{\"delta\":{\"content\":\"llo\"},\"finish_reason\":null}]}",
    acc,
    on_chunk,
  )
  assert_false(d2)
  let d3 = process_chat_completions_sse(
    provider="testprov",
    "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}",
    acc,
    on_chunk,
  )
  assert_true(d3)
  let completion = acc.to_completion()
  match completion.message.content[0] {
    @posoco.Content::Text(t) => assert_eq(t, "hello")
    _ => fail("expected text content")
  }
  match completion.message.reasoning {
    Some(r) => assert_eq(r.content, "think")
    None => fail("expected reasoning")
  }
}

///|
test "tool call assembles across deltas" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let chunks : Array[@posoco.StreamChunk] = []
  let on_chunk = fn(chunk : @posoco.StreamChunk) -> Unit { chunks.push(chunk) }
  let first = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"echo\",\"arguments\":\"\"}}]},\"finish_reason\":null}]}"
  assert_false(
    process_chat_completions_sse(provider="testprov", first, acc, on_chunk),
  )
  let cont = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"text\\\":\\\"hi\\\"}\"}}]},\"finish_reason\":null}]}"
  assert_false(
    process_chat_completions_sse(provider="testprov", cont, acc, on_chunk),
  )
  let completion = acc.to_completion()
  assert_eq(completion.message.tool_calls.length(), 1)
  let tc = completion.message.tool_calls[0]
  assert_eq(tc.call_id.to_string(), "call_1")
  assert_eq(tc.name.to_string(), "echo")
  assert_eq(tc.arguments.stringify(), "{\"text\":\"hi\"}")
}

///|
test "explicit nulls in tool-call continuation chunks are treated as absent" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let chunks : Array[@posoco.StreamChunk] = []
  let on_chunk = fn(chunk : @posoco.StreamChunk) -> Unit { chunks.push(chunk) }
  // First delta carries the id and name; arguments start as explicit null.
  let first = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"echo\",\"arguments\":null}}]},\"finish_reason\":null}]}"
  assert_false(
    process_chat_completions_sse(provider="testprov", first, acc, on_chunk),
  )
  // Continuation delta: some compatible servers serialize absent fields as
  // explicit null instead of omitting the keys.
  let cont = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":null,\"function\":{\"name\":null,\"arguments\":\"{\\\"text\\\":\\\"hi\\\"}\"}}]},\"finish_reason\":null}]}"
  assert_false(
    process_chat_completions_sse(provider="testprov", cont, acc, on_chunk),
  )
  let completion = acc.to_completion()
  assert_eq(completion.message.tool_calls.length(), 1)
  let tc = completion.message.tool_calls[0]
  assert_eq(tc.call_id.to_string(), "call_1")
  assert_eq(tc.name.to_string(), "echo")
  assert_eq(tc.arguments.stringify(), "{\"text\":\"hi\"}")
}

///|
test "content-free chunks are skipped without emitting chunks" {
  // Keepalive / preamble object with no choices, usage, or error.
  let (done1, _, chunks1) = run_sse(
    "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\"}",
  )
  assert_false(done1)
  assert_eq(chunks1.length(), 0)
  // A choice with neither delta nor finish_reason.
  let (done2, _, chunks2) = run_sse(
    "{\"choices\":[{\"index\":0,\"finish_reason\":null}]}",
  )
  assert_false(done2)
  assert_eq(chunks2.length(), 0)
  // Explicit null delta.
  let (done3, _, chunks3) = run_sse(
    "{\"choices\":[{\"delta\":null,\"finish_reason\":null}]}",
  )
  assert_false(done3)
  assert_eq(chunks3.length(), 0)
}

///|
test "empty choices array carries usage when present" {
  let (done, acc, chunks) = run_sse(
    "{\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}",
  )
  assert_false(done)
  assert_eq(chunks.length(), 1)
  let completion = acc.to_completion()
  match completion.usage {
    Some(u) => {
      assert_eq(u.input_tokens, Some(10))
      assert_eq(u.output_tokens, Some(5))
    }
    None => fail("expected usage")
  }
}

///|
test "usage-only chunk without choices is accepted" {
  let (done, _, chunks) = run_sse(
    "{\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,\"total_tokens\":3}}",
  )
  assert_false(done)
  assert_eq(chunks.length(), 1)
}

///|
test "mid-stream error object is a provider failure, not a parse failure" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let chunks : Array[@posoco.StreamChunk] = []
  let on_chunk = fn(chunk : @posoco.StreamChunk) -> Unit { chunks.push(chunk) }
  let result = Ok(
    process_chat_completions_sse(
      provider="testprov",
      "{\"error\":{\"message\":\"rate limited\",\"type\":\"rate_limit\"}}",
      acc,
      on_chunk,
    ),
  ) catch {
    err => Err(err)
  }
  match result {
    Err(@posoco.ModelError::Transport(msg)) => {
      assert_true(msg.contains("testprov SSE stream failure"))
      assert_true(msg.contains("stage=error"))
      assert_true(msg.contains("category=provider_error"))
      // Provider payload never crosses into the message.
      assert_true(!msg.contains("rate limited"))
    }
    _ => fail("expected Transport provider_error")
  }
}

///|
test "loud failures keep their stage labels" {
  let cases : Array[(String, String)] = [
    ("not json", "stage=json"),
    ("[]", "stage=event, category=not_object"),
    ("{\"choices\":{}}", "stage=choices, category=wrong_type"),
    ("{\"choices\":[[]]}", "stage=choice, category=not_object"),
    (
      "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":-1,\"function\":{\"name\":\"x\"}}]},\"finish_reason\":null}]}",
      "stage=tool.index, category=negative",
    ),
    (
      "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"name\":\"x\"}}]},\"finish_reason\":null}]}",
      "stage=tool.index, category=missing",
    ),
    (
      "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":42,\"function\":{\"name\":\"x\"}}]},\"finish_reason\":null}]}",
      "stage=tool.id, category=wrong_type",
    ),
    (
      "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"\",\"function\":{\"name\":\"x\"}}]},\"finish_reason\":null}]}",
      "stage=tool.id, category=empty",
    ),
    (
      "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c\"}]},\"finish_reason\":null}]}",
      "stage=tool.function, category=missing",
    ),
    (
      "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":null}}]},\"finish_reason\":null}]}",
      "stage=tool.function, category=empty",
    ),
    ("{\"usage\":42}", "stage=usage, category=wrong_type"),
    ("{\"choices\":[],\"usage\":42}", "stage=usage, category=wrong_type"),
    (
      "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":42}", "stage=usage, category=wrong_type",
    ),
    (
      "{\"choices\":[{\"delta\":{\"content\":42},\"finish_reason\":null}]}", "stage=delta.content, category=wrong_type",
    ),
    (
      "{\"choices\":[{\"finish_reason\":\"\"}]}", "stage=finish_reason, category=empty",
    ),
    ("{\"error\":\"boom\"}", "stage=error, category=wrong_type"),
  ]
  for case in cases {
    let (data, expected) = case
    let acc = @posoco.StreamAccumulator::StreamAccumulator()
    let chunks : Array[@posoco.StreamChunk] = []
    let on_chunk = fn(chunk : @posoco.StreamChunk) -> Unit {
      chunks.push(chunk)
    }
    let result = Ok(
      process_chat_completions_sse(provider="testprov", data, acc, on_chunk),
    ) catch {
      err => Err(err)
    }
    match result {
      Err(err) => {
        let msg = err.to_string()
        assert_true(msg.contains(expected))
        assert_true(msg.contains("testprov"))
      }
      Ok(_) => fail("expected failure for \{data}")
    }
  }
}

///|
test "explicit null usage is treated as absent on every branch" {
  // Observed from a real gateway (opencode-zen): "usage": null on chunks.
  // Finish chunk with null usage finishes without emitting usage.
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let chunks : Array[@posoco.StreamChunk] = []
  let on_chunk = fn(chunk : @posoco.StreamChunk) -> Unit { chunks.push(chunk) }
  let done = process_chat_completions_sse(
    provider="testprov",
    "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":null}",
    acc,
    on_chunk,
  )
  assert_true(done)
  assert_eq(chunks.length(), 1) // only Finish, no Usage
  assert_true(acc.usage_total is None)
  // Empty choices + null usage: content-free skip.
  let (done2, _, chunks2) = run_sse("{\"choices\":[],\"usage\":null}")
  assert_false(done2)
  assert_eq(chunks2.length(), 0)
  // No choices + null usage: content-free skip.
  let (done3, _, chunks3) = run_sse("{\"usage\":null}")
  assert_false(done3)
  assert_eq(chunks3.length(), 0)
}

///|
test "provider error chunk surfaces bounded type/code labels only" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let noop = fn(chunk : @posoco.StreamChunk) -> Unit { ignore(chunk) }
  // Enum-like type + string code cross into the message.
  let r1 = Ok(
    process_chat_completions_sse(
      provider="testprov",
      "{\"error\":{\"type\":\"CreditsError\",\"code\":\"402\",\"message\":\"Insufficient balance. Manage your billing here: https://x\"}}",
      acc,
      noop,
    ),
  ) catch {
    err => Err(err)
  }
  match r1 {
    Err(@posoco.ModelError::Transport(msg)) => {
      assert_true(msg.contains("category=provider_error"))
      assert_true(msg.contains("error_type=CreditsError"))
      assert_true(msg.contains("error_code=402"))
      // Free-text fields never cross.
      assert_true(!msg.contains("Insufficient balance"))
    }
    _ => fail("expected Transport with bounded labels")
  }
  // Numeric code is rendered as an integer label.
  let r2 = Ok(
    process_chat_completions_sse(
      provider="testprov",
      "{\"error\":{\"type\":\"rate_limit_error\",\"code\":429}}",
      acc,
      noop,
    ),
  ) catch {
    err => Err(err)
  }
  match r2 {
    Err(@posoco.ModelError::Transport(msg)) => {
      assert_true(msg.contains("error_type=rate_limit_error"))
      assert_true(msg.contains("error_code=429"))
    }
    _ => fail("expected Transport with numeric code")
  }
  // Free-text-ish or oversized labels are dropped, message stays bare.
  let long_type = String::make(65, 'a')
  let r3 = Ok(
    process_chat_completions_sse(
      provider="testprov",
      "{\"error\":{\"type\":\"insufficient balance for this request\",\"code\":\"\{long_type}\"}}",
      acc,
      noop,
    ),
  ) catch {
    err => Err(err)
  }
  match r3 {
    Err(@posoco.ModelError::Transport(msg)) => {
      assert_true(!msg.contains("error_type="))
      assert_true(!msg.contains("error_code="))
      assert_true(!msg.contains("insufficient balance"))
    }
    _ => fail("expected Transport without labels")
  }
}

///|
test "cached_input_tokens_from_usage accepts every known spelling" {
  let usage_of = fn(pairs : Array[(String, Json)]) -> Map[String, Json] {
    Map::from_array(pairs)
  }
  // OpenAI spelling.
  let openai = usage_of([
    (
      "prompt_tokens_details",
      Json::object(Map::from_array([("cached_tokens", Json::number(1000.0))])),
    ),
  ])
  assert_eq(cached_input_tokens_from_usage(openai), Some(1000))
  // DeepSeek spelling.
  let deepseek = usage_of([("prompt_cache_hit_tokens", Json::number(700.0))])
  assert_eq(cached_input_tokens_from_usage(deepseek), Some(700))
  // Moonshot top-level spelling.
  let moonshot = usage_of([("cached_tokens", Json::number(80.0))])
  assert_eq(cached_input_tokens_from_usage(moonshot), Some(80))
  // Anthropic-compat gateway spelling.
  let anthropic = usage_of([("cache_read_input_tokens", Json::number(90.0))])
  assert_eq(cached_input_tokens_from_usage(anthropic), Some(90))
  // DeepSeek reports the miss side natively.
  let deepseek_miss = usage_of([
    ("prompt_cache_miss_tokens", Json::number(200.0)),
  ])
  assert_eq(uncached_input_tokens_from_usage(deepseek_miss), Some(200))
  assert_true(uncached_input_tokens_from_usage(openai) is None)
  // Absent and malformed spellings read as None, never a parse failure.
  let none_reported = usage_of([("prompt_tokens", Json::number(10.0))])
  assert_true(cached_input_tokens_from_usage(none_reported) is None)
  let malformed = usage_of([("cached_tokens", Json::string("n/a"))])
  assert_true(cached_input_tokens_from_usage(malformed) is None)
}
