///|
/// SSE tests: framing, the full event vocabulary, malformed lifecycles,
/// usage snapshots, and decoder isolation. Fixtures follow the documented
/// wire shapes (terminal is `message_stop`; `ping` never completes).

///|
/// One framed SSE event line pair.
fn ev(name~ : String, data~ : Json) -> String {
  "event: " + name + "\ndata: " + data.stringify()
}

///|
/// Join framed events with the blank-line separator SSE requires.
fn sse(events : Array[String]) -> String {
  let builder = StringBuilder()
  for i, event in events {
    if i > 0 {
      builder.write_string("\n\n")
    }
    builder.write_string(event)
  }
  builder.write_string("\n\n")
  builder.to_string()
}

///|
/// Drain framed SSE text through the framer + event processor.
/// Returns (done, collected chunks, final state).
fn feed_sse(
  text~ : String,
  acc~ : @posoco.StreamAccumulator,
) -> (Bool, Array[@posoco.StreamChunk], MessagesSseState) raise @posoco.ModelError {
  let decoder = SseDecoder::SseDecoder()
  let state = MessagesSseState::MessagesSseState()
  let chunks : Array[@posoco.StreamChunk] = []
  let mut done = false
  for event in decoder.push(text) {
    if process_messages_event(
      provider="test",
      event_name=event.name,
      data=event.data,
      acc~,
      on_chunk={ chunk => chunks.push(chunk) },
      state~,
    ) {
      done = true
    }
  }
  decoder.flush()
  (done, chunks, state)
}

///|
fn message_start(id~ : String, input~ : Int32) -> String {
  ev(
    name="message_start",
    data={
      "type": "message_start",
      "message": {
        "id": id,
        "type": "message",
        "role": "assistant",
        "model": "m",
        "content": [],
        "stop_reason": None,
        "stop_sequence": None,
        "usage": { "input_tokens": input, "output_tokens": 1 },
      },
    },
  )
}

///|
test "streaming text splits across many events into a correct completion" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let (done, chunks, state) = feed_sse(
    text=sse([
      message_start(id="msg_s1", input=25),
      ev(name="content_block_start", data={
        "type": "content_block_start",
        "index": 0,
        "content_block": { "type": "text", "text": "" },
      }),
      ev(name="content_block_delta", data={
        "type": "content_block_delta",
        "index": 0,
        "delta": { "type": "text_delta", "text": "Hel" },
      }),
      ev(name="content_block_delta", data={
        "type": "content_block_delta",
        "index": 0,
        "delta": { "type": "text_delta", "text": "lo" },
      }),
      ev(name="content_block_delta", data={
        "type": "content_block_delta",
        "index": 0,
        "delta": { "type": "text_delta", "text": " world" },
      }),
      ev(name="content_block_stop", data={
        "type": "content_block_stop",
        "index": 0,
      }),
      ev(name="message_delta", data={
        "type": "message_delta",
        "delta": { "stop_reason": "end_turn", "stop_sequence": None },
        "usage": { "output_tokens": 12 },
      }),
      ev(name="message_stop", data={ "type": "message_stop" }),
    ]),
    acc~,
  )
  assert_true(done)
  assert_eq(acc.text(), "Hello world")
  assert_eq(chunks.length(), 5)
  // Three text deltas + terminal Finish + final Usage.
  // The Usage chunk appears exactly once despite the cumulative snapshots.
  let mut usage_chunks = 0
  for chunk in chunks {
    match chunk {
      @posoco.StreamChunk::Usage(..) => usage_chunks += 1
      _ => ()
    }
  }
  assert_eq(usage_chunks, 1)
  let result = messages_stream_result(provider="test", acc~, state~)
  assert_eq(
    result.completion.message.content,
    [@posoco.Content::Text("Hello world")],
  )
  assert_eq(
    result.completion.message.finish_reason,
    @posoco.FinishReason::Stop,
  )
  assert_eq(result.response_id, "msg_s1")
  let usage = result.usage.unwrap_or({
    input_tokens: 0,
    output_tokens: 0,
    cache_creation_input_tokens: None,
    cache_read_input_tokens: None,
  })
  assert_eq(usage.input_tokens, 25)
  assert_eq(usage.output_tokens, 12)
  let canonical = result.completion.usage.unwrap_or({
    input_tokens: None,
    output_tokens: None,
    total_tokens: None,
    cached_input_tokens: None,
    uncached_input_tokens: None,
  })
  assert_eq(canonical.total_tokens, Some(37))
}

///|
test "tool arguments split across arbitrary JSON fragment boundaries" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let (done, chunks, state) = feed_sse(
    text=sse([
      message_start(id="msg_t", input=9),
      ev(name="content_block_start", data={
        "type": "content_block_start",
        "index": 0,
        "content_block": {
          "type": "tool_use",
          "id": "toolu_x",
          "name": "write",
          "input": {},
        },
      }),
      ev(name="content_block_delta", data={
        "type": "content_block_delta",
        "index": 0,
        "delta": { "type": "input_json_delta", "partial_json": "{\"path\":" },
      }),
      ev(name="content_block_delta", data={
        "type": "content_block_delta",
        "index": 0,
        "delta": {
          "type": "input_json_delta",
          "partial_json": "\"a.txt\", \"body\": ",
        },
      }),
      ev(name="content_block_delta", data={
        "type": "content_block_delta",
        "index": 0,
        "delta": { "type": "input_json_delta", "partial_json": "\"hi\"}" },
      }),
      ev(name="content_block_delta", data={
        "type": "content_block_delta",
        "index": 0,
        "delta": { "type": "input_json_delta", "partial_json": None },
      }),
      ev(name="content_block_stop", data={
        "type": "content_block_stop",
        "index": 0,
      }),
      ev(name="message_delta", data={
        "type": "message_delta",
        "delta": { "stop_reason": "tool_use" },
        "usage": { "output_tokens": 40 },
      }),
      ev(name="message_stop", data={ "type": "message_stop" }),
    ]),
    acc~,
  )
  assert_true(done)
  let result = messages_stream_result(provider="test", acc~, state~)
  let calls = result.completion.message.tool_calls
  assert_eq(calls.length(), 1)
  assert_eq(calls[0].call_id.to_string(), "toolu_x")
  assert_eq(calls[0].name.to_string(), "write")
  assert_eq(calls[0].arguments, { "path": "a.txt", "body": "hi" })
  assert_eq(
    result.completion.message.finish_reason,
    @posoco.FinishReason::ToolCalls,
  )
  // Tool-call deltas carried the identity plus three argument fragments.
  let mut arg_fragments = 0
  for chunk in chunks {
    match chunk {
      @posoco.StreamChunk::ToolCallDelta(arguments_delta=Some(_), ..) =>
        arg_fragments += 1
      _ => ()
    }
  }
  assert_eq(arg_fragments, 3)
}

///|
test "interleaved thinking, signature, and tool calls replay losslessly" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let (done, chunks, state) = feed_sse(
    text=sse([
      message_start(id="msg_i", input=5),
      ev(name="content_block_start", data={
        "type": "content_block_start",
        "index": 0,
        "content_block": { "type": "thinking", "thinking": "" },
      }),
      ev(name="content_block_delta", data={
        "type": "content_block_delta",
        "index": 0,
        "delta": { "type": "thinking_delta", "thinking": "Think" },
      }),
      ev(name="content_block_delta", data={
        "type": "content_block_delta",
        "index": 0,
        "delta": { "type": "thinking_delta", "thinking": " hard." },
      }),
      ev(name="content_block_delta", data={
        "type": "content_block_delta",
        "index": 0,
        "delta": { "type": "signature_delta", "signature": "sig-99" },
      }),
      ev(name="content_block_stop", data={
        "type": "content_block_stop",
        "index": 0,
      }),
      ev(name="content_block_start", data={
        "type": "content_block_start",
        "index": 1,
        "content_block": { "type": "text", "text": "" },
      }),
      ev(name="content_block_delta", data={
        "type": "content_block_delta",
        "index": 1,
        "delta": { "type": "text_delta", "text": "On it." },
      }),
      ev(name="content_block_stop", data={
        "type": "content_block_stop",
        "index": 1,
      }),
      ev(name="content_block_start", data={
        "type": "content_block_start",
        "index": 2,
        "content_block": {
          "type": "tool_use",
          "id": "toolu_i",
          "name": "f",
          "input": {},
        },
      }),
      ev(name="content_block_delta", data={
        "type": "content_block_delta",
        "index": 2,
        "delta": { "type": "input_json_delta", "partial_json": "{}" },
      }),
      ev(name="content_block_stop", data={
        "type": "content_block_stop",
        "index": 2,
      }),
      ev(name="message_delta", data={
        "type": "message_delta",
        "delta": { "stop_reason": "tool_use" },
        "usage": { "output_tokens": 22 },
      }),
      ev(name="message_stop", data={ "type": "message_stop" }),
    ]),
    acc~,
  )
  assert_true(done)
  let result = messages_stream_result(provider="test", acc~, state~)
  assert_eq(acc.text(), "On it.")
  assert_eq(acc.reasoning(), "Think hard.")
  assert_eq(result.completion.message.tool_calls.length(), 1)
  let assistant = @posoco.Message::AssistantMessage(
    content=result.completion.message.content,
    tool_calls=result.completion.message.tool_calls,
    reasoning=result.completion.message.reasoning,
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  let blocks = jget(message_to_wire(assistant)[0], key="content")
  assert_eq(jget(jat(blocks, index=0), key="type"), "thinking")
  assert_eq(jget(jat(blocks, index=0), key="thinking"), "Think hard.")
  assert_eq(jget(jat(blocks, index=0), key="signature"), "sig-99")
  assert_eq(jget(jat(blocks, index=1), key="type"), "text")
  assert_eq(jget(jat(blocks, index=2), key="id"), "toolu_i")
  // ReasoningDelta chunks streamed to the sink as well.
  let mut reasoning_deltas = 0
  for chunk in chunks {
    match chunk {
      @posoco.StreamChunk::ReasoningDelta(..) => reasoning_deltas += 1
      _ => ()
    }
  }
  assert_eq(reasoning_deltas, 2)
}

///|
test "redacted thinking arrives complete and pings never complete" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let (done, chunks, state) = feed_sse(
    text=sse([
      message_start(id="msg_r", input=3),
      ev(name="ping", data={ "type": "ping" }),
      ev(name="content_block_start", data={
        "type": "content_block_start",
        "index": 0,
        "content_block": { "type": "redacted_thinking", "data": "ZW5j" },
      }),
      ev(name="content_block_stop", data={
        "type": "content_block_stop",
        "index": 0,
      }),
      ev(name="content_block_start", data={
        "type": "content_block_start",
        "index": 1,
        "content_block": { "type": "text", "text": "" },
      }),
      ev(name="content_block_delta", data={
        "type": "content_block_delta",
        "index": 1,
        "delta": { "type": "text_delta", "text": "ok" },
      }),
      ev(name="content_block_stop", data={
        "type": "content_block_stop",
        "index": 1,
      }),
      ev(name="message_delta", data={
        "type": "message_delta",
        "delta": { "stop_reason": "end_turn" },
        "usage": { "output_tokens": 2 },
      }),
      ev(name="message_stop", data={ "type": "message_stop" }),
    ]),
    acc~,
  )
  assert_true(done)
  assert_eq(chunks.length(), 3)
  let result = messages_stream_result(provider="test", acc~, state~)
  let assistant = @posoco.Message::AssistantMessage(
    content=result.completion.message.content,
    tool_calls=result.completion.message.tool_calls,
    reasoning=result.completion.message.reasoning,
    finish_reason=@posoco.FinishReason::Stop,
  )
  let blocks = jget(message_to_wire(assistant)[0], key="content")
  assert_eq(jget(jat(blocks, index=0), key="type"), "redacted_thinking")
  assert_eq(jget(jat(blocks, index=0), key="data"), "ZW5j")
  assert_eq(jget(jat(blocks, index=1), key="text"), "ok")
}

///|
test "unknown events are ignored and do not complete the stream" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let (done, chunks, state) = feed_sse(
    text=sse([
      message_start(id="msg_f", input=1),
      ev(name="future_thing", data={ "type": "future_thing", "x": 1 }),
      ev(name="content_block_start", data={
        "type": "content_block_start",
        "index": 0,
        "content_block": { "type": "text", "text": "" },
      }),
      ev(name="content_block_delta", data={
        "type": "content_block_delta",
        "index": 0,
        "delta": { "type": "text_delta", "text": "a" },
      }),
      ev(name="content_block_stop", data={
        "type": "content_block_stop",
        "index": 0,
      }),
      ev(name="message_delta", data={
        "type": "message_delta",
        "delta": { "stop_reason": "end_turn" },
      }),
      ev(name="message_stop", data={ "type": "message_stop" }),
    ]),
    acc~,
  )
  assert_true(done)
  // TextDelta, Finish and final cumulative Usage are all emitted.
  assert_eq(chunks.length(), 3)
  assert_eq(state.response_id, "msg_f")
}

///|
test "mid-stream error events are protocol failures, not output" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let result = Ok(
    feed_sse(
      text=sse([
        message_start(id="msg_e", input=1),
        ev(name="error", data={
          "type": "error",
          "error": {
            "type": "overloaded_error",
            "message": "Overloaded free-form detail",
          },
        }),
      ]),
      acc~,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.ModelError::Transport(message)) => {
      assert_true(message.contains("overloaded_error"))
      // Bounded diagnostics: the free-text provider message never echoes.
      assert_false(message.contains("free-form"))
    }
    _ => fail("expected mid-stream error failure")
  }
}

///|
test "truncated streams and missing message_stop are typed errors" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let (done, _, _) = feed_sse(
    text=sse([
      message_start(id="msg_tr", input=1),
      ev(name="content_block_start", data={
        "type": "content_block_start",
        "index": 0,
        "content_block": { "type": "text", "text": "" },
      }),
      ev(name="content_block_delta", data={
        "type": "content_block_delta",
        "index": 0,
        "delta": { "type": "text_delta", "text": "partial" },
      }),
    ]),
    acc~,
  )
  assert_false(done)
  match classify_stream_termination(provider="test", CleanEof) {
    Some(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("message_stop"))
    _ => fail("expected truncation error")
  }
}

///|
test "malformed json and invalid indices are rejected with bounded detail" {
  let bad_json = Ok(
    process_messages_event(
      provider="test",
      data="{not json",
      acc=@posoco.StreamAccumulator::StreamAccumulator(),
      on_chunk={ _ => () },
    ),
  ) catch {
    error => Err(error)
  }
  match bad_json {
    Err(@posoco.ModelError::ResponseParse(message)) => {
      assert_true(message.contains("stage=json"))
      // Bounded: the payload never echoes into the diagnostic.
      assert_false(message.contains("not json"))
    }
    _ => fail("expected json parse failure")
  }
  let bad_index = Ok(
    process_messages_event(
      provider="test",
      data=({
        "type": "content_block_start",
        "index": -1,
        "content_block": { "type": "text", "text": "" },
      } : Json).stringify(),
      acc=@posoco.StreamAccumulator::StreamAccumulator(),
      on_chunk={ _ => () },
    ),
  ) catch {
    error => Err(error)
  }
  match bad_index {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("stage=index"))
    _ => fail("expected index rejection")
  }
}

///|
test "malformed block lifecycles are rejected" {
  let state = MessagesSseState::MessagesSseState()
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  // Delta before message_start.
  let early = Ok(
    process_messages_event(
      provider="test",
      data=({
        "type": "content_block_start",
        "index": 0,
        "content_block": { "type": "text", "text": "" },
      } : Json).stringify(),
      acc~,
      on_chunk={ _ => () },
      state~,
    ),
  ) catch {
    error => Err(error)
  }
  match early {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("block_before_start"))
    _ => fail("expected pre-start rejection")
  }
  // Happy prefix, then a duplicate stop.
  let _ = process_messages_event(
    provider="test",
    data=({
        "type": "message_start",
        "message": {
          "id": "m",
          "role": "assistant",
          "model": "m",
          "type": "message",
        },
      } : Json).stringify(),
    acc~,
    on_chunk={ _ => () },
    state~,
  )
  let _ = process_messages_event(
    provider="test",
    data=({
        "type": "content_block_start",
        "index": 0,
        "content_block": { "type": "text", "text": "" },
      } : Json).stringify(),
    acc~,
    on_chunk={ _ => () },
    state~,
  )
  let _ = process_messages_event(
    provider="test",
    data=({ "type": "content_block_stop", "index": 0 } : Json).stringify(),
    acc~,
    on_chunk={ _ => () },
    state~,
  )
  let double_stop = Ok(
    process_messages_event(
      provider="test",
      data=({ "type": "content_block_stop", "index": 0 } : Json).stringify(),
      acc~,
      on_chunk={ _ => () },
      state~,
    ),
  ) catch {
    error => Err(error)
  }
  match double_stop {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("double_stop"))
    _ => fail("expected double stop rejection")
  }
  // Events after message_stop.
  let closed = MessagesSseState::MessagesSseState()
  let acc2 = @posoco.StreamAccumulator::StreamAccumulator()
  // message_stop without a started message is invalid, not a terminal.
  let early_stop = Ok(process_messages_event(
    provider="test",
    data=({ "type": "message_stop" } : Json).stringify(),
    acc=acc2,
    on_chunk={ _ => () },
    state=closed,
  )) catch { error => Err(error) }
  match early_stop {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("incomplete_message"))
    _ => fail("expected incomplete-message rejection")
  }
  // An independent complete zero-content message can close normally.
  let _ = process_messages_event(
    provider="test",
    data=({
      "type": "message_start",
      "message": { "type": "message", "id": "m", "model": "m", "role": "assistant" },
    } : Json).stringify(),
    acc=acc2,
    on_chunk={ _ => () },
    state=closed,
  )
  let _ = process_messages_event(
    provider="test",
    data=({
      "type": "message_delta",
      "delta": { "stop_reason": "end_turn" },
    } : Json).stringify(),
    acc=acc2,
    on_chunk={ _ => () },
    state=closed,
  )
  let _ = process_messages_event(
    provider="test",
    data=({ "type": "message_stop" } : Json).stringify(),
    acc=acc2,
    on_chunk={ _ => () },
    state=closed,
  )
  let after = Ok(
    process_messages_event(
      provider="test",
      data=({ "type": "ping" } : Json).stringify(),
      acc=acc2,
      on_chunk={ _ => () },
      state=closed,
    ),
  ) catch {
    error => Err(error)
  }
  match after {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("event_after_stop"))
    _ => fail("expected post-stop rejection")
  }
  // Assembling before the terminal event is a typed error.
  let premature = Ok(messages_stream_result(
    provider="test",
    acc=@posoco.StreamAccumulator::StreamAccumulator(),
    state=MessagesSseState::MessagesSseState(),
  )) catch {
    error => Err(error)
  }
  match premature {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("missing_message_stop"))
    _ => fail("expected premature assembly rejection")
  }
}

///|
test "incomplete tool arguments reject at block completion" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let result = Ok(
    feed_sse(
      text=sse([
        message_start(id="msg_z", input=1),
        ev(name="content_block_start", data={
          "type": "content_block_start",
          "index": 0,
          "content_block": {
            "type": "tool_use",
            "id": "toolu_z",
            "name": "f",
            "input": {},
          },
        }),
        ev(name="content_block_delta", data={
          "type": "content_block_delta",
          "index": 0,
          "delta": { "type": "input_json_delta", "partial_json": "{\"a\":" },
        }),
        ev(name="content_block_stop", data={
          "type": "content_block_stop",
          "index": 0,
        }),
      ]),
      acc~,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("tool.arguments"))
    _ => fail("expected incomplete tool arguments rejection")
  }
}

///|
test "cumulative usage snapshots replace per dimension, never sum" {
  let state = MessagesSseState::MessagesSseState()
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let mut done = false
  for event in SseDecoder::SseDecoder().push(
    sse([
      message_start(id="msg_u", input=100),
      ev(name="content_block_start", data={
        "type": "content_block_start",
        "index": 0,
        "content_block": { "type": "text", "text": "" },
      }),
      ev(name="content_block_stop", data={
        "type": "content_block_stop",
        "index": 0,
      }),
      ev(name="message_delta", data={
        "type": "message_delta",
        "delta": { "stop_reason": "end_turn" },
        "usage": { "output_tokens": 5 },
      }),
      ev(name="message_delta", data={
        "type": "message_delta",
        "delta": { "stop_reason": "end_turn" },
        "usage": {
          "output_tokens": 9,
          "cache_read_input_tokens": 80,
          "cache_creation_input_tokens": 7,
        },
      }),
      ev(name="message_stop", data={ "type": "message_stop" }),
    ]),
  ) {
    if process_messages_event(
      provider="test",
      event_name=event.name,
      data=event.data,
      acc~,
      on_chunk={ _ => () },
      state~,
    ) {
      done = true
    }
  }
  assert_true(done)
  let result = messages_stream_result(provider="test", acc~, state~)
  let usage = result.usage.unwrap_or({
    input_tokens: 0,
    output_tokens: 0,
    cache_creation_input_tokens: None,
    cache_read_input_tokens: None,
  })
  assert_eq(usage.input_tokens, 100)
  // Latest snapshot wins: 9, not 5+9.
  assert_eq(usage.output_tokens, 9)
  assert_eq(usage.cache_read_input_tokens, Some(80))
  assert_eq(usage.cache_creation_input_tokens, Some(7))
  // The single canonical Usage chunk carries the merged projection.
  let canonical = result.completion.usage.unwrap_or({
    input_tokens: None,
    output_tokens: None,
    total_tokens: None,
    cached_input_tokens: None,
    uncached_input_tokens: None,
  })
  assert_eq(canonical.input_tokens, Some(187))
  assert_eq(canonical.cached_input_tokens, Some(80))
  assert_eq(canonical.uncached_input_tokens, Some(107))
}

///|
test "independent decoder instances are fully isolated" {
  let text = sse([
    message_start(id="msg_s", input=1),
    ev(name="content_block_start", data={
      "type": "content_block_start",
      "index": 0,
      "content_block": { "type": "text", "text": "" },
    }),
    ev(name="content_block_delta", data={
      "type": "content_block_delta",
      "index": 0,
      "delta": { "type": "text_delta", "text": "a" },
    }),
    ev(name="content_block_stop", data={
      "type": "content_block_stop",
      "index": 0,
    }),
    ev(name="message_delta", data={
      "type": "message_delta",
      "delta": { "stop_reason": "end_turn" },
    }),
    ev(name="message_stop", data={ "type": "message_stop" }),
  ])
  let acc_a = @posoco.StreamAccumulator::StreamAccumulator()
  let acc_b = @posoco.StreamAccumulator::StreamAccumulator()
  let (done_a, chunks_a, state_a) = feed_sse(text=text, acc=acc_a)
  let (done_b, chunks_b, state_b) = feed_sse(text=text, acc=acc_b)
  assert_true(done_a)
  assert_true(done_b)
  assert_eq(chunks_a, chunks_b)
  assert_eq(acc_a.text(), acc_b.text())
  assert_eq(state_a.response_id, state_b.response_id)
  // A decoder holding a partial line keeps it private; a fresh decoder
  // never sees another instance's bytes.
  let partial = SseDecoder::SseDecoder()
  assert_eq(partial.push("data: {\"type\":\"pi").length(), 0)
  let fresh = SseDecoder::SseDecoder()
  assert_eq(fresh.push("ng\"}\n\n").length(), 0)
  assert_eq(partial.push("ng\"}\n\n").length(), 1)
}


///|
/// An unknown delta on an otherwise known text block must not silently erase
/// semantics. Only unknown *event names* are ignorable.
test "unknown semantic deltas fail instead of losing content" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let result = Ok(feed_sse(
    text=sse([
      message_start(id="msg_unknown_delta", input=1),
      ev(name="content_block_start", data={
        "type": "content_block_start",
        "index": 0,
        "content_block": { "type": "text", "text": "" },
      }),
      ev(name="content_block_delta", data={
        "type": "content_block_delta",
        "index": 0,
        "delta": { "type": "future_semantic_delta", "payload": "invisible" },
      }),
    ]),
    acc~,
  )) catch { error => Err(error) }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("unsupported"))
    _ => fail("expected unsupported delta rejection")
  }
}
