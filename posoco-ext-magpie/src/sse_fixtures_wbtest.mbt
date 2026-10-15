///|
/// sse_fixtures_wbtest.mbt — deterministic SSE/response fixtures for the
/// execution suite. Wire shapes mirror the protocol kits' own contracts;
/// the fake gateway replays them as raw lines.

///|
/// One SSE event as raw wire lines.
fn sse_event(name : String, data : Json) -> Array[String] {
  ["event: \{name}", "data: \{data.stringify()}", ""]
}

///|
/// Flattens event line-groups into one stream script.
fn sse_script(groups : Array[Array[String]]) -> Array[String] {
  let lines : Array[String] = []
  for group in groups {
    for line in group {
      lines.push(line)
    }
  }
  lines
}

///|
fn msg_start(id~ : String, model~ : String) -> Array[String] {
  sse_event(
    "message_start",
    Json::object({
      "type": Json::string("message_start"),
      "message": Json::object({
        "id": Json::string(id),
        "type": Json::string("message"),
        "role": Json::string("assistant"),
        "model": Json::string(model),
        "content": Json::array([]),
        "stop_reason": Json::null(),
        "stop_sequence": Json::null(),
        "usage": Json::object({
          "input_tokens": Json::number(9),
          "output_tokens": Json::number(1),
        }),
      }),
    }),
  )
}

///|
fn block_start(index~ : Int, block~ : Json) -> Array[String] {
  sse_event(
    "content_block_start",
    Json::object({
      "type": Json::string("content_block_start"),
      "index": Json::number(index.to_double()),
      "content_block": block,
    }),
  )
}

///|
fn block_delta(index~ : Int, delta~ : Json) -> Array[String] {
  sse_event(
    "content_block_delta",
    Json::object({
      "type": Json::string("content_block_delta"),
      "index": Json::number(index.to_double()),
      "delta": delta,
    }),
  )
}

///|
fn block_stop(index~ : Int) -> Array[String] {
  sse_event(
    "content_block_stop",
    Json::object({
      "type": Json::string("content_block_stop"),
      "index": Json::number(index.to_double()),
    }),
  )
}

///|
fn msg_delta(stop_reason~ : String, output_tokens~ : Int) -> Array[String] {
  sse_event(
    "message_delta",
    Json::object({
      "type": Json::string("message_delta"),
      "delta": Json::object({
        "stop_reason": Json::string(stop_reason),
        "stop_sequence": Json::null(),
      }),
      "usage": Json::object({
        "output_tokens": Json::number(output_tokens.to_double()),
      }),
    }),
  )
}

///|
fn msg_stop() -> Array[String] {
  sse_event("message_stop", Json::object({ "type": Json::string("message_stop") }))
}

///|
/// A streaming Messages turn: thinking (with signature), then text.
fn messages_thinking_stream() -> Array[String] {
  sse_script([
    msg_start(id="msg_think", model="claude-served"),
    block_start(
      index=0,
      block=Json::object({
        "type": Json::string("thinking"),
        "thinking": Json::string(""),
      }),
    ),
    block_delta(
      index=0,
      delta=Json::object({
        "type": Json::string("thinking_delta"),
        "thinking": Json::string("figuring it out"),
      }),
    ),
    block_delta(
      index=0,
      delta=Json::object({
        "type": Json::string("signature_delta"),
        "signature": Json::string("sig-abc=="),
      }),
    ),
    block_stop(index=0),
    block_start(
      index=1,
      block=Json::object({
        "type": Json::string("text"),
        "text": Json::string(""),
      }),
    ),
    block_delta(
      index=1,
      delta=Json::object({
        "type": Json::string("text_delta"),
        "text": Json::string("the answer"),
      }),
    ),
    block_stop(index=1),
    msg_delta(stop_reason="end_turn", output_tokens=21),
    msg_stop(),
  ])
}

///|
/// A streaming Messages turn ending in one tool call.
fn messages_tool_stream() -> Array[String] {
  sse_script([
    msg_start(id="msg_tool", model="claude-served"),
    block_start(
      index=0,
      block=Json::object({
        "type": Json::string("tool_use"),
        "id": Json::string("toolu_1"),
        "name": Json::string("read"),
      }),
    ),
    block_delta(
      index=0,
      delta=Json::object({
        "type": Json::string("input_json_delta"),
        "partial_json": Json::string("{\"path\": \"x\"}"),
      }),
    ),
    block_stop(index=0),
    msg_delta(stop_reason="tool_use", output_tokens=9),
    msg_stop(),
  ])
}

///|
/// An incomplete Messages stream: the lifecycle stops before message_stop.
fn messages_truncated_stream() -> Array[String] {
  sse_script([
    msg_start(id="msg_trunc", model="claude-served"),
    block_start(
      index=0,
      block=Json::object({
        "type": Json::string("text"),
        "text": Json::string(""),
      }),
    ),
    block_delta(
      index=0,
      delta=Json::object({
        "type": Json::string("text_delta"),
        "text": Json::string("partial"),
      }),
    ),
  ])
}

///|
/// Responses SSE payloads are data-only lines.
fn resp_data(payload : Json) -> Array[String] {
  ["data: \{payload.stringify()}"]
}

///|
/// A streaming Responses turn ending in text plus usage.
fn responses_text_stream() -> Array[String] {
  sse_script([
    resp_data(
      Json::object({
        "type": Json::string("response.output_text.delta"),
        "delta": Json::string("hel"),
      }),
    ),
    resp_data(
      Json::object({
        "type": Json::string("response.output_text.delta"),
        "delta": Json::string("lo"),
      }),
    ),
    resp_data(
      Json::object({
        "type": Json::string("response.completed"),
        "response": Json::object({
          "id": Json::string("resp_stream_1"),
          "model": Json::string("gpt-responses-served"),
          "status": Json::string("completed"),
          "output": Json::array([]),
          "usage": Json::object({
            "input_tokens": Json::number(4),
            "output_tokens": Json::number(2),
            "total_tokens": Json::number(6),
          }),
        }),
      }),
    ),
  ])
}

///|
/// A buffered Responses completion with a reasoning item for replay.
fn responses_nonstream_body(text~ : String, reasoning_item~ : Json) -> String {
  Json::object({
    "id": Json::string("resp_1"),
    "model": Json::string("gpt-responses-served"),
    "status": Json::string("completed"),
    "output": Json::array([
      reasoning_item,
      Json::object({
        "type": Json::string("message"),
        "role": Json::string("assistant"),
        "content": Json::array([
          Json::object({
            "type": Json::string("output_text"),
            "text": Json::string(text),
          }),
        ]),
      }),
    ]),
    "usage": Json::object({
      "input_tokens": Json::number(11),
      "output_tokens": Json::number(3),
      "total_tokens": Json::number(14),
    }),
  })
  .stringify()
}

///|
/// A buffered Chat Completions completion.
fn chat_nonstream_body(text~ : String) -> String {
  Json::object({
    "id": Json::string("chatcmpl-1"),
    "model": Json::string("gpt-chat-served"),
    "choices": Json::array([
      Json::object({
        "index": Json::number(0),
        "message": Json::object({
          "role": Json::string("assistant"),
          "content": Json::string(text),
        }),
        "finish_reason": Json::string("stop"),
      }),
    ]),
    "usage": Json::object({
      "prompt_tokens": Json::number(5),
      "completion_tokens": Json::number(2),
      "total_tokens": Json::number(7),
    }),
  })
  .stringify()
}

///|
fn chat_chunk(delta~ : Json, finish~ : String?) -> Array[String] {
  let choice_fields : Array[(String, Json)] = [
    ("index", Json::number(0)),
    ("delta", delta),
  ]
  match finish {
    Some(reason) =>
      choice_fields.push(("finish_reason", Json::string(reason)))
    None => ()
  }
  let payload = Json::object({
    "choices": Json::array([Json::object(Map::from_array(choice_fields))]),
  })
  [
    "data: \{payload.stringify()}",
  ]
}

///|
fn chat_usage_chunk() -> Array[String] {
  let payload = Json::object({
    "choices": Json::array([]),
    "usage": Json::object({
      "prompt_tokens": Json::number(6),
      "completion_tokens": Json::number(4),
      "total_tokens": Json::number(10),
    }),
  })
  ["data: \{payload.stringify()}"]
}

///|
/// Streaming Chat Completions lines: text, then two parallel tool calls,
/// then finish and usage.
fn chat_parallel_tool_stream() -> Array[String] {
  sse_script([
    chat_chunk(
      delta=Json::object({
        "role": Json::string("assistant"),
        "content": Json::string("checking"),
      }),
      finish=None,
    ),
    chat_chunk(
      delta=Json::object({
        "tool_calls": Json::array([
          Json::object({
            "index": Json::number(0),
            "id": Json::string("call_a"),
            "type": Json::string("function"),
            "function": Json::object({
              "name": Json::string("read"),
              "arguments": Json::string(""),
            }),
          }),
        ]),
      }),
      finish=None,
    ),
    chat_chunk(
      delta=Json::object({
        "tool_calls": Json::array([
          Json::object({
            "index": Json::number(0),
            "function": Json::object({
              "arguments": Json::string("{\"path\":\"a\"}"),
            }),
          }),
        ]),
      }),
      finish=None,
    ),
    chat_chunk(
      delta=Json::object({
        "tool_calls": Json::array([
          Json::object({
            "index": Json::number(1),
            "id": Json::string("call_b"),
            "type": Json::string("function"),
            "function": Json::object({
              "name": Json::string("stat"),
              "arguments": Json::string("{\"path\":\"b\"}"),
            }),
          }),
        ]),
      }),
      finish=None,
    ),
    chat_chunk(
      delta=Json::object({}),
      finish=Some("tool_calls"),
    ),
    chat_usage_chunk(),
    ["data: [DONE]"],
  ])
}

///|
/// A buffered Messages completion with native cache usage numbers.
fn messages_nonstream_body(text~ : String) -> String {
  Json::object({
    "type": Json::string("message"),
    "id": Json::string("msg_1"),
    "model": Json::string("claude-served"),
    "role": Json::string("assistant"),
    "content": Json::array([
      Json::object({ "type": Json::string("text"), "text": Json::string(text) }),
    ]),
    "stop_reason": Json::string("end_turn"),
    "stop_sequence": Json::null(),
    "usage": Json::object({
      "input_tokens": Json::number(7),
      "output_tokens": Json::number(2),
    }),
  })
  .stringify()
}
