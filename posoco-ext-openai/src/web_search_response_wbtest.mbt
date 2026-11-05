///|
/// Hosted OpenAI Web Search response handling (provider-local).
///
/// The approved seams are the public `OpenAIModelPort.chat` HTTP loopback
/// (`CompactLoopback`, reused from the compact transport tests) and the process
/// `EventSystem` the devkit status publishers write to. Every assertion reads
/// what the production chat path produced: the returned `Completion`, the bytes
/// the next turn puts on the wire, and the status operations a host renders.
/// No provider-local helper is called directly.

///|
/// Wrap fixture events as one SSE body: each event is one `data:` line plus the
/// blank-line separator the SSE reader tolerates.
#cfg(target="native")
fn wsr_sse(events : Array[String]) -> String {
  events.map(fn(event) { "data: " + event + "\n\n" }).join("")
}

///|
/// One hosted search turn mixing every item shape an effort-tuned request
/// produces: reasoning first, the hosted `web_search_call` items (search, then
/// open_page), the answer message carrying a `url_citation`, and a local
/// function call. The terminal `response.completed` repeats the full output
/// array — the shape the platform API uses (Codex's backend sends `[]`).
#cfg(target="native")
fn wsr_mixed_events() -> Array[String] {
  let citation = "{\"type\":\"url_citation\",\"start_index\":0,\"end_index\":11,\"title\":\"Planet Nine\",\"url\":\"https://example.com/planet\"}"
  let reasoning_done = "{\"type\":\"reasoning\",\"id\":\"rs_wsr\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"先检索。\"}],\"content\":[],\"encrypted_content\":\"enc-done\"}"
  let search_done = "{\"type\":\"web_search_call\",\"id\":\"ws_search\",\"status\":\"completed\",\"action\":{\"type\":\"search\",\"query\":\"planet nine\"},\"encrypted_content\":\"enc-search\"}"
  let open_done = "{\"type\":\"web_search_call\",\"id\":\"ws_open\",\"status\":\"completed\",\"action\":{\"type\":\"open_page\",\"url\":\"https://example.com/planet\"}}"
  let message_done = "{\"type\":\"message\",\"id\":\"msg_wsr\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Planet Nine has a source.\",\"annotations\":[" +
    citation +
    "]}]}"
  let call_done = "{\"type\":\"function_call\",\"id\":\"fc_wsr\",\"status\":\"completed\",\"arguments\":\"{\\\"path\\\":\\\"/tmp/wsr.txt\\\"}\",\"call_id\":\"call_wsr\",\"name\":\"read\"}"
  [
    "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_wsr\",\"status\":\"in_progress\",\"output\":[]}}",
    "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_wsr\",\"summary\":[],\"content\":[],\"encrypted_content\":\"enc-added\"}}",
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" +
    reasoning_done +
    "}",
    "{\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"web_search_call\",\"id\":\"ws_search\",\"status\":\"in_progress\"}}",
    "{\"type\":\"response.web_search_call.in_progress\",\"item_id\":\"ws_search\",\"output_index\":1}",
    "{\"type\":\"response.web_search_call.searching\",\"item_id\":\"ws_search\",\"output_index\":1}",
    "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":" +
    search_done +
    "}",
    "{\"type\":\"response.web_search_call.completed\",\"item_id\":\"ws_search\",\"output_index\":1}",
    "{\"type\":\"response.output_item.added\",\"output_index\":2,\"item\":{\"type\":\"web_search_call\",\"id\":\"ws_open\",\"status\":\"in_progress\"}}",
    "{\"type\":\"response.output_item.done\",\"output_index\":2,\"item\":" +
    open_done +
    "}",
    "{\"type\":\"response.output_text.delta\",\"output_index\":3,\"content_index\":0,\"delta\":\"Planet Nine \"}",
    "{\"type\":\"response.output_text.delta\",\"output_index\":3,\"content_index\":0,\"delta\":\"has a source.\"}",
    "{\"type\":\"response.output_text.annotation.added\",\"item_id\":\"msg_wsr\",\"output_index\":3,\"content_index\":0,\"annotation\":" +
    citation +
    "}",
    "{\"type\":\"response.output_item.done\",\"output_index\":3,\"item\":" +
    message_done +
    "}",
    "{\"type\":\"response.output_item.added\",\"output_index\":4,\"item\":{\"type\":\"function_call\",\"id\":\"fc_wsr\",\"status\":\"in_progress\",\"arguments\":\"\",\"call_id\":\"call_wsr\",\"name\":\"read\"}}",
    "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":4,\"item_id\":\"fc_wsr\",\"delta\":\"{\\\"path\\\":\"}",
    "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":4,\"item_id\":\"fc_wsr\",\"delta\":\"\\\"/tmp/wsr.txt\\\"}\"}",
    "{\"type\":\"response.output_item.done\",\"output_index\":4,\"item\":" +
    call_done +
    "}",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_wsr\",\"status\":\"completed\",\"output\":[" +
    reasoning_done +
    "," +
    search_done +
    "," +
    open_done +
    "," +
    message_done +
    "," +
    call_done +
    "],\"usage\":{\"input_tokens\":11,\"output_tokens\":7,\"total_tokens\":18}}}",
  ]
}

///|
#cfg(target="native")
fn wsr_scope(session_id : String) -> @posoco.InvocationScope {
  @posoco.InvocationScope::{
    session_id: @posoco.SessionId::unchecked(session_id),
    run_id: @posoco.RunId::unchecked("run-1"),
    effect_id: None,
    pressure: None,
  }
}

///|
/// Streaming chat turns against the loopback fixture, in order. The production
/// port owns the request, the SSE decode and the finish.
#cfg(target="native")
async fn wsr_chat_stream(
  replies : Array[String],
  turns : Array[Array[@posoco.Message]],
  session_id : String,
) -> (
  Array[Result[@posoco.ModelCallResult, @posoco.ModelError]],
  CompactLoopback,
) {
  let loopback = CompactLoopback::bind(
    replies.map(fn(body) { Respond(status=200, body~, headers=[], delay_ms=0) }),
  )
  let results : Array[Result[@posoco.ModelCallResult, @posoco.ModelError]] = []
  @async.with_timeout(20000, () => {
    @async.with_task_group() <| group => {
      defer loopback.stop()
      let _ = group.spawn(() => loopback.serve(), allow_failure=true)
      let port = OpenAIModelPort::OpenAIModelPort(
        OpenAIConfig::with_base_url(
          "wsr-test-key",
          "gpt-5",
          "http://127.0.0.1:\{loopback.server.addr.port()}/v1",
        ),
      )
      for turn in turns {
        let outcome = Ok(
          port.chat(
            wsr_scope(session_id),
            turn,
            [],
            { temperature: None, max_output_tokens: None, },
            @posoco.StreamMode::Stream(_ => ()),
          ),
        ) catch {
          err => Err(err)
        }
        results.push(outcome)
      }
    }
  })
  (results, loopback)
}

///|
/// One non-streaming chat turn against the loopback fixture: the production
/// `chat` non-stream path, which must decode a hosted response with the same
/// projection and envelope as the stream.
#cfg(target="native")
async fn wsr_chat_nonstream(
  reply : String,
  session_id : String,
) -> (Result[@posoco.ModelCallResult, @posoco.ModelError], CompactLoopback) {
  let loopback = CompactLoopback::bind([
    Respond(status=200, body=reply, headers=[], delay_ms=0),
  ])
  let mut outcome : Result[@posoco.ModelCallResult, @posoco.ModelError] = Err(
    @posoco.ModelError::Transport("the chat call never ran"),
  )
  @async.with_timeout(20000, () => {
    @async.with_task_group() <| group => {
      defer loopback.stop()
      let _ = group.spawn(() => loopback.serve(), allow_failure=true)
      let port = OpenAIModelPort::OpenAIModelPort(
        OpenAIConfig::with_base_url(
          "wsr-test-key",
          "gpt-5",
          "http://127.0.0.1:\{loopback.server.addr.port()}/v1",
        ),
      )
      outcome = Ok(
        port.chat(
          wsr_scope(session_id),
          [wsr_user_message("planet nine?")],
          [],
          { temperature: None, max_output_tokens: None, },
          @posoco.StreamMode::NoStream,
        ),
      ) catch {
        err => Err(err)
      }
    }
  })
  (outcome, loopback)
}

///|
#cfg(target="native")
fn wsr_user_message(text : String) -> @posoco.Message {
  @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)])
}

///|
/// The visible assistant text of a completion.
#cfg(target="native")
fn wsr_text(completion : @posoco.Completion) -> String {
  completion.message.content
  .map(fn(part) {
    match part {
      @posoco.Content::Text(text) => text
      _ => ""
    }
  })
  .join("")
}

///|
/// The provider-private raw envelope payload carried on `Reasoning.raw`.
#cfg(target="native")
fn wsr_envelope(completion : @posoco.Completion) -> Map[String, Json] raise {
  guard completion.message.reasoning
    is Some({ raw: Some(Json::Object(fields)), .. }) else {
    fail("a hosted search turn must attach the private raw envelope")
  }
  guard fields.get("posoco.openai.web_search_raw_output")
    is Some(Json::Object(payload)) else {
    fail("the envelope must use its own versioned key")
  }
  payload
}

///|
/// The ordered `id` of every raw output item in the envelope: the replay order
/// contract, readable without opening the item payloads.
#cfg(target="native")
fn wsr_envelope_ids(payload : Map[String, Json]) -> Array[String] raise {
  guard payload.get("output") is Some(Json::Array(items)) else {
    fail("the envelope must carry the raw output array")
  }
  items.map(fn(item) raise {
    guard item is Json::Object(fields) else {
      fail("raw item must be an object")
    }
    match fields.get("id") {
      Some(Json::String(id)) => id
      _ => fail("raw item must carry its provider id")
    }
  })
}

///|
/// Every status envelope this executable published, across all test blocks.
///
/// The devkit publishers write to one process-wide default `EventSystem` with
/// last-write-wins registration, and test blocks of a package run concurrently:
/// a recorder owned by one test can receive a peer's operations, and its own
/// turn's operations can land in a peer's recorder. Both directions are handled
/// by logging into one shared array — whichever system is current writes here —
/// and selecting one turn's operations by its session-scoped segment, which is
/// unique per test.
#cfg(target="native")
let wsr_status_events : Array[@posoco.EventEnvelope] = []

///|
/// Make the current default system one that logs into the shared array, and
/// return that array.
#cfg(target="native")
fn wsr_status_log() -> Array[@posoco.EventEnvelope] {
  let system = @posoco.EventSystem()
  @devkit.events_system_register(system)
  match system.subscribe(fn(envelope) { wsr_status_events.push(envelope) }) {
    Ok(_) => ()
    Err(_) => abort("status recorder subscription failed")
  }
  wsr_status_events
}

///|
#cfg(target="native")
fn wsr_op_segment(op : @kit_events.StatusOp) -> String {
  match op {
    @kit_events.StatusOp::Register(segment~, ..) => segment
    @kit_events.StatusOp::Update(segment~, ..) => segment
    @kit_events.StatusOp::Unregister(segment~) => segment
  }
}

///|
/// Every status operation that touched a web-search segment of this run.
#cfg(target="native")
fn wsr_web_search_ops(
  events : Array[@posoco.EventEnvelope],
  session_id : String,
) -> Array[@kit_events.StatusOp] {
  let ops : Array[@kit_events.StatusOp] = []
  for envelope in events {
    match @kit_events.status_changed_of(envelope) {
      Some(op) =>
        // One segment per turn, named after the session: filtering on it keeps
        // an unrelated turn of the same process out of these assertions.
        if wsr_op_segment(op).contains("web_search:\{session_id}:") {
          ops.push(op)
        }
      None => ()
    }
  }
  ops
}

///|
/// Publisher identity of each web-search status envelope: the provider owns the
/// activity, so a host can attribute it and a peer cannot claim it.
#cfg(target="native")
fn wsr_web_search_publishers(
  events : Array[@posoco.EventEnvelope],
  session_id : String,
) -> Array[String] {
  let publishers : Array[String] = []
  for envelope in events {
    match @kit_events.status_changed_of(envelope) {
      Some(op) =>
        if wsr_op_segment(op).contains("web_search:\{session_id}:") {
          match @kit_events.publisher_id(envelope) {
            Some(id) => publishers.push(id)
            None => publishers.push("")
          }
        }
      None => ()
    }
  }
  publishers
}

///|
/// End-to-end: a streamed turn with hosted search renders the citation inline,
/// captures the whole raw output in wire order exactly once, and publishes the
/// search activity on a turn-scoped segment released when the turn ends.
#cfg(target="native")
async test "web search stream renders inline citation and captures raw output" {
  let events = wsr_status_log()
  let stream_turns : Array[Array[@posoco.Message]] = [
    [wsr_user_message("planet nine?")],
  ]
  let (results, loopback) = wsr_chat_stream(
    [wsr_sse(wsr_mixed_events())],
    stream_turns,
    "wsr-stream",
  )
  guard results[0] is Ok(result) else {
    fail("the hosted search stream must complete")
  }
  let completion = result.completion
  // The citation is inline at its position — not a trailing source list — and
  // its label repeats the provider's own words.
  assert_eq(
    wsr_text(completion),
    "[Planet Nine](https://example.com/planet) has a source.",
  )
  // A local function call in the same turn is untouched: a hosted tool never
  // masquerades as a client-executed one, and vice versa.
  let calls = completion.tool_calls()
  assert_eq(calls.length(), 1)
  assert_eq(calls[0].call_id.to_string(), "call_wsr")
  assert_eq(calls[0].name.to_string(), "read")
  // Raw output: every item once, in wire order, done snapshots winning.
  assert_eq(wsr_envelope_ids(wsr_envelope(completion)), [
    "rs_wsr", "ws_search", "ws_open", "msg_wsr", "fc_wsr",
  ])
  // Search activity is announced on the turn's own segment and released.
  let ops = wsr_web_search_ops(events, "wsr-stream")
  assert_eq(ops.length(), 3)
  guard ops[0]
    is @kit_events.StatusOp::Register(
      segment~,
      label~,
      priority~,
      value~,
      color~
    ) else {
    fail("the first web search operation must register the segment")
  }
  assert_true(segment.contains("wsr-stream"))
  assert_eq(label, Some("web_search"))
  assert_eq(priority, 44)
  assert_eq(value, Some("searching"))
  assert_eq(color, Some("info"))
  assert_eq(ops[1], @kit_events.StatusOp::Update(segment~, value="open_page"))
  assert_eq(ops[2], @kit_events.StatusOp::Unregister(segment~))
  let publishers = wsr_web_search_publishers(events, "wsr-stream")
  assert_eq(publishers.length(), 3)
  for publisher in publishers {
    assert_eq(publisher, "posoco_ext_openai")
  }
  assert_eq(loopback.requests.length(), 1)
  assert_eq(loopback.requests[0].path, "/v1/responses")
}

///|
/// The assistant message a host appends to the session after a turn, built from
/// the completion exactly the way the kernel would.
#cfg(target="native")
fn wsr_assistant_message(completion : @posoco.Completion) -> @posoco.Message {
  @posoco.Message::AssistantMessage(
    content=completion.message.content,
    tool_calls=completion.message.tool_calls,
    reasoning=completion.message.reasoning,
    finish_reason=completion.message.finish_reason,
  )
}

///|
/// The follow-up turn's raw output items: the replayed window between the two
/// user messages, which is where exactness has to show up.
#cfg(target="native")
fn wsr_request_input(body : String) -> Array[Json] raise {
  guard @json.parse(body) is Json::Object(fields) else {
    fail("request body must be a JSON object")
  }
  match fields.get("input") {
    Some(Json::Array(items)) => items
    _ => fail("request body must carry an input array")
  }
}

///|
/// One item of the request input, as an object.
#cfg(target="native")
fn wsr_input_object(
  items : Array[Json],
  index : Int32,
) -> Map[String, Json] raise {
  guard items[index] is Json::Object(fields) else {
    fail("input item must be an object")
  }
  fields
}

///|
/// The text of one `message` item in a request input.
#cfg(target="native")
fn wsr_input_text(fields : Map[String, Json]) -> String raise {
  guard fields.get("content") is Some(Json::Array(parts)) else {
    fail("message item must carry content parts")
  }
  guard parts[0] is Json::Object(part) &&
    part.get("text") is Some(Json::String(text)) else {
    fail("content part must carry text")
  }
  text
}

///|
/// A follow-up answer with no hosted activity: the plain path must keep
/// working next to a hosted turn.
#cfg(target="native")
fn wsr_plain_events() -> String {
  wsr_sse([
    "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"ok\"}",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_plain\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"id\":\"msg_plain\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}]}}",
  ])
}

///|
/// The next request replays the stored raw output exactly once each, in wire
/// order, and never the display projection: the model sees what it actually
/// sent, the user sees the citations.
#cfg(target="native")
async test "web search raw output replays once and the projection stays visible" {
  let first_turns : Array[Array[@posoco.Message]] = [
    [wsr_user_message("planet nine?")],
    [wsr_user_message("planet nine?")],
  ]
  let (first, _log) = wsr_chat_stream(
    [wsr_sse(wsr_mixed_events()), wsr_plain_events()],
    first_turns,
    "wsr-replay",
  )
  // The first turn ran alone; rebuild it with the assistant message a host
  // would append, then ask again in the same session.
  guard first[0] is Ok(result) else {
    fail("the hosted search turn must complete")
  }
  let assistant = wsr_assistant_message(result.completion)
  let tool_result = @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("call_wsr"),
    tool_name=@posoco.ToolName::unchecked("read"),
    outcome=@posoco.ToolOutcome::Success(
      content="file contents",
      structured=None,
    ),
  )
  let turn = [
    wsr_user_message("planet nine?"),
    assistant,
    tool_result,
    wsr_user_message("and again?"),
  ]
  let replay_turns : Array[Array[@posoco.Message]] = [turn]
  let (second, loopback) = wsr_chat_stream(
    [wsr_plain_events()],
    replay_turns,
    "wsr-replay",
  )
  guard second[0] is Ok(_) else { fail("the replay turn must complete") }
  let items = wsr_request_input(loopback.bodies[0])
  // user, then the five stored raw items, then the tool result, then the new
  // question: the message and function_call items are replayed, not regenerated.
  assert_eq(items.length(), 8)
  assert_eq(wsr_input_object(items, 0).get("role"), Some(Json::string("user")))
  assert_eq(wsr_input_object(items, 1).get("id"), Some(Json::string("rs_wsr")))
  assert_eq(
    wsr_input_object(items, 1).get("encrypted_content"),
    Some(Json::string("enc-done")),
  )
  assert_eq(
    wsr_input_object(items, 2).get("id"),
    Some(Json::string("ws_search")),
  )
  assert_eq(wsr_input_object(items, 3).get("id"), Some(Json::string("ws_open")))
  let message = wsr_input_object(items, 4)
  assert_eq(message.get("id"), Some(Json::string("msg_wsr")))
  // The wire text is the provider's own, never the citation projection.
  assert_eq(wsr_input_text(message), "Planet Nine has a source.")
  let call = wsr_input_object(items, 5)
  assert_eq(call.get("type"), Some(Json::string("function_call")))
  assert_eq(call.get("call_id"), Some(Json::string("call_wsr")))
  let output = wsr_input_object(items, 6)
  assert_eq(output.get("type"), Some(Json::string("function_call_output")))
  assert_eq(output.get("call_id"), Some(Json::string("call_wsr")))
  assert_eq(wsr_input_object(items, 7).get("role"), Some(Json::string("user")))
  // No duplicate hosted item and no rewritten text anywhere on the wire.
  assert_false(loopback.bodies[0].contains("](https://example.com/planet)"))
  let mut hosted_items = 0
  for item in items {
    match item {
      Json::Object(fields) =>
        if fields.get("id") == Some(Json::string("ws_search")) {
          hosted_items += 1
        }
      _ => ()
    }
  }
  assert_eq(hosted_items, 1)
}

///|
/// A JSON string literal for fixture splicing, so provider-shaped text (CJK,
/// emoji, quotes) reaches the fixture exactly as it would arrive.
#cfg(target="native")
fn wsr_json_string(text : String) -> String {
  Json::string(text).stringify()
}

///|
/// One answer turn carrying `annotations` inline: citations without any hosted
/// call, which must still project.
#cfg(target="native")
fn wsr_answer_events(text : String, annotations : Array[String]) -> String {
  let message = "{\"type\":\"message\",\"id\":\"msg_ans\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":" +
    wsr_json_string(text) +
    ",\"annotations\":[" +
    annotations.join(",") +
    "]}]}"
  wsr_sse([
    "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":" +
    wsr_json_string(text) +
    "}",
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" +
    message +
    "}",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_ans\",\"status\":\"completed\",\"output\":[" +
    message +
    "]}}",
  ])
}

///|
/// One answer turn with several text parts in a single message item, and the
/// citations for each part addressed by `(content index, annotation)`. With
/// `inline`, the done item carries the annotations itself (the shape the
/// platform returns, so it is what the next request replays); without it they
/// arrive only as `annotation.added` events, which is the streaming shape whose
/// part binding has to be recovered from the event's own content index.
#cfg(target="native")
fn wsr_multipart_events(
  parts : Array[String],
  annotations : Array[(Int32, String)],
  inline~ : Bool,
  with_content_index~ : Bool = true,
) -> String {
  let content : Array[String] = []
  for index, text in parts {
    let own : Array[String] = []
    if inline {
      for entry in annotations {
        if entry.0 == index {
          own.push(entry.1)
        }
      }
    }
    // A part with no annotations has no key at all: an empty array would tell
    // the provider-local projection that the item states its own (empty) truth.
    let part = "{\"type\":\"output_text\",\"text\":" + wsr_json_string(text)
    content.push(
      if own.is_empty() {
        part + "}"
      } else {
        part + ",\"annotations\":[" + own.join(",") + "]}"
      },
    )
  }
  let message = "{\"type\":\"message\",\"id\":\"msg_parts\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[" +
    content.join(",") +
    "]}"
  let events : Array[String] = []
  for index, text in parts {
    events.push(
      "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":" +
      index.to_string() +
      ",\"delta\":" +
      wsr_json_string(text) +
      "}",
    )
  }
  if !inline {
    for entry in annotations {
      events.push(
        "{\"type\":\"response.output_text.annotation.added\",\"item_id\":\"msg_parts\",\"output_index\":0" +
        (if with_content_index {
          ",\"content_index\":" + entry.0.to_string()
        } else {
          ""
        }) +
        ",\"annotation\":" +
        entry.1 +
        "}",
      )
    }
  }
  events.push(
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" +
    message +
    "}",
  )
  events.push(
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_parts\",\"status\":\"completed\",\"output\":[" +
    message +
    "]}}",
  )
  wsr_sse(events)
}

///|
#cfg(target="native")
fn wsr_citation(start_index : Int32, end_index : Int32, url : String) -> String {
  "{\"type\":\"url_citation\",\"start_index\":" +
  start_index.to_string() +
  ",\"end_index\":" +
  end_index.to_string() +
  ",\"title\":\"Source\",\"url\":" +
  wsr_json_string(url) +
  "}"
}

///|
/// Two properties of a multi-part answer in one test, both from the outside:
/// citation offsets are UTF-16 code units (MoonBit iterates Unicode scalars, and
/// CJK text plus an astral emoji pins the conversion), and the next request
/// replays the raw item with the provider's original text *and* original
/// `annotations` — the projection shown to the user never reaches the wire.
#cfg(target="native")
async test "web search citation offsets follow UTF-16 units and the wire keeps the original annotations" {
  // 看 = unit 0, 😀 = units 1-2, 这 = 3, 里 = 4: the span "这里" is 3..5.
  let wording = wsr_citation(3, 5, "https://example.com/zh")
  // Unit 2 is the trailing half of the surrogate pair: unaddressable, so the
  // projection drops the link while the annotation itself survives.
  let broken = wsr_citation(2, 4, "https://example.com/broken")
  let annotations = [(0, wording), (0, broken)]
  let turns : Array[Array[@posoco.Message]] = [[wsr_user_message("查一下")]]
  let (results, _loopback) = wsr_chat_stream(
    [wsr_multipart_events(["看😀这里"], annotations, inline=true)],
    turns,
    "wsr-unicode",
  )
  guard results[0] is Ok(result) else {
    fail("the citation turn must complete")
  }
  assert_eq(
    wsr_text(result.completion),
    "看😀[这里](https://example.com/zh)",
  )
  // Next turn: the replayed message item is the provider's own raw item, with
  // its text and both annotations untouched, and no projection on the wire.
  let assistant = wsr_assistant_message(result.completion)
  let replay_turns : Array[Array[@posoco.Message]] = [
    [wsr_user_message("查一下"), assistant, wsr_user_message("再查")],
  ]
  let (replay, loopback) = wsr_chat_stream(
    [wsr_plain_events()],
    replay_turns,
    "wsr-unicode",
  )
  guard replay[0] is Ok(_) else { fail("the replayed turn must complete") }
  let items = wsr_request_input(loopback.bodies[0])
  let message = wsr_input_object(items, 1)
  guard message.get("content") is Some(Json::Array(parts)) else {
    fail("the replayed message item must keep its content parts")
  }
  guard parts[0] is Json::Object(part) else {
    fail("the replayed content part must be an object")
  }
  assert_eq(part.get("text"), Some(Json::string("看😀这里")))
  assert_eq(
    part.get("annotations"),
    Some(@json.parse("[" + wording + "," + broken + "]")),
  )
  assert_false(loopback.bodies[0].contains("](https://example.com/zh)"))
}

///|
/// A message item may hold several text parts, and each part indexes its own
/// annotations: a citation that arrived as `annotation.added` must bind to the
/// part its content index names, not to the first text part of the item.
#cfg(target="native")
async test "web search annotation.added binds by content index across text parts" {
  let first = wsr_citation(0, 5, "https://example.com/first")
  let second = wsr_citation(0, 6, "https://example.com/second")
  let turns : Array[Array[@posoco.Message]] = [[wsr_user_message("two parts")]]
  let (results, _loopback) = wsr_chat_stream(
    [
      wsr_multipart_events(
        ["first part", "second"],
        [(0, first), (1, second)],
        inline=false,
      ),
    ],
    turns,
    "wsr-parts",
  )
  guard results[0] is Ok(result) else {
    fail("the multi-part citation turn must complete")
  }
  assert_eq(
    wsr_text(result.completion),
    "[first](https://example.com/first) part[second](https://example.com/second)",
  )
}

///|
/// Citation destinations cannot become executable or break out of Markdown:
/// reject executable schemes, encode URL parentheses, and escape label brackets.
#cfg(target="native")
async test "web search citations cannot inject markdown or executable urls" {
  let turns : Array[Array[@posoco.Message]] = [
    [wsr_user_message("one")],
    [wsr_user_message("two")],
    [wsr_user_message("three")],
  ]
  let (results, _loopback) = wsr_chat_stream(
    [
      wsr_answer_events("点击这里", [
        wsr_citation(0, 4, "javascript:alert(1)"),
      ]),
      wsr_answer_events("see the page", [
        wsr_citation(4, 12, "https://example.com/a)b"),
      ]),
      wsr_answer_events("a]b", [wsr_citation(0, 3, "https://example.com/x")]),
    ],
    turns,
    "wsr-injection",
  )
  guard results[0] is Ok(scripted) else {
    fail("the javascript: citation turn must complete")
  }
  assert_eq(wsr_text(scripted.completion), "点击这里")
  guard results[1] is Ok(parenthesis) else {
    fail("the parenthesis citation turn must complete")
  }
  assert_eq(
    wsr_text(parenthesis.completion),
    "see [the page](https://example.com/a%29b)",
  )
  guard results[2] is Ok(bracketed) else {
    fail("the bracketed label turn must complete")
  }
  // The label is escaped, so the cited words still render as one link.
  assert_eq(wsr_text(bracketed.completion), "[a\\]b](https://example.com/x)")
}

///|
/// The non-stream transport decodes a hosted response with the same projection
/// and the same envelope as the stream.
#cfg(target="native")
async test "web search non-stream response projects and stores the envelope" {
  let answer = "{\"type\":\"message\",\"id\":\"msg_ns\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Answer from a page.\",\"annotations\":[" +
    wsr_citation(12, 18, "https://example.com/p") +
    "]}]}"
  let body = "{\"id\":\"resp_ns\",\"status\":\"completed\",\"output\":[{\"type\":\"web_search_call\",\"id\":\"ws_ns\",\"status\":\"completed\",\"action\":{\"type\":\"search\",\"query\":\"q\"}}," +
    answer +
    "],\"usage\":{\"input_tokens\":5,\"output_tokens\":6,\"total_tokens\":11}}"
  let events = wsr_status_log()
  let (outcome, loopback) = wsr_chat_nonstream(body, "wsr-nonstream")
  guard outcome is Ok(result) else {
    fail("the non-stream hosted response must complete")
  }
  assert_eq(
    wsr_text(result.completion),
    "Answer from [a page](https://example.com/p).",
  )
  assert_eq(wsr_envelope_ids(wsr_envelope(result.completion)), [
    "ws_ns", "msg_ns",
  ])
  assert_eq(result.completion.usage.unwrap().total_tokens, Some(11))
  // The non-stream request is not a stream request.
  assert_false(loopback.bodies[0].contains("\"stream\":true"))
  // A non-stream response has no progress to show: the search already finished
  // before the body arrived, so no activity segment may be announced (and a
  // finished search may not be re-announced as still running).
  assert_eq(wsr_web_search_ops(events, "wsr-nonstream").length(), 0)
}

///|
/// Repeated `added`/`done` snapshots for one item must collapse into one raw
/// item, and the `done` (complete) snapshot is the one that survives.
#cfg(target="native")
async test "web search duplicate added and done snapshots collapse to one raw item" {
  let sse = wsr_sse([
    "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"web_search_call\",\"id\":\"ws_dup\",\"status\":\"in_progress\"}}",
    "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"web_search_call\",\"id\":\"ws_dup\",\"status\":\"in_progress\"}}",
    "{\"type\":\"response.web_search_call.searching\",\"item_id\":\"ws_dup\",\"output_index\":0}",
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"web_search_call\",\"id\":\"ws_dup\",\"status\":\"completed\",\"action\":{\"type\":\"search\",\"query\":\"dup\"}}}",
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"web_search_call\",\"id\":\"ws_dup\",\"status\":\"completed\",\"action\":{\"type\":\"search\",\"query\":\"dup\"}}}",
    "{\"type\":\"response.output_text.delta\",\"output_index\":1,\"delta\":\"answer\"}",
    "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"message\",\"id\":\"msg_dup\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}}",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_dup\",\"status\":\"completed\",\"output\":[]}}",
  ])
  let turns : Array[Array[@posoco.Message]] = [[wsr_user_message("dup")]]
  let (results, _loopback) = wsr_chat_stream([sse], turns, "wsr-dedupe")
  guard results[0] is Ok(result) else {
    fail("the duplicate-snapshot stream must complete")
  }
  assert_eq(wsr_text(result.completion), "answer")
  let payload = wsr_envelope(result.completion)
  assert_eq(wsr_envelope_ids(payload), ["ws_dup", "msg_dup"])
  guard payload.get("output") is Some(Json::Array(items)) else {
    fail("the envelope must carry the raw output array")
  }
  guard items[0] is Json::Object(hosted) else {
    fail("the hosted item must stay an object")
  }
  // The complete snapshot won, not the in-progress announcement.
  assert_eq(hosted.get("status"), Some(Json::string("completed")))
  assert_false(payload.contains("citations"))
}

///|
/// A malformed *known* payload fails the turn instead of being swallowed: the
/// raw output is what the next request replays, so a silently dropped citation
/// would corrupt the conversation rather than surface the provider contract
/// break.
#cfg(target="native")
async test "web search malformed citation is a loud failure" {
  let sse = wsr_answer_events("answer text", [
    "{\"type\":\"url_citation\",\"start_index\":\"zero\",\"end_index\":6,\"title\":\"t\",\"url\":\"https://example.com/x\"}",
  ])
  let turns : Array[Array[@posoco.Message]] = [[wsr_user_message("broken")]]
  let (results, _loopback) = wsr_chat_stream([sse], turns, "wsr-malformed")
  guard results[0] is Err(@posoco.ModelError::ResponseParse(message)) else {
    fail("a malformed citation offset must raise ResponseParse")
  }
  assert_true(message.contains("stage=start_index"))
  assert_true(message.contains("category=wrong_type"))
}

///|
/// A failed stream releases the activity segment: the search is no longer
/// running, and a later turn must not inherit a stale segment.
#cfg(target="native")
async test "web search failure releases the activity segment" {
  let events = wsr_status_log()
  let sse = wsr_sse([
    "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"web_search_call\",\"id\":\"ws_fail\",\"status\":\"in_progress\"}}",
    "{\"type\":\"response.web_search_call.searching\",\"item_id\":\"ws_fail\",\"output_index\":0}",
    "{\"type\":\"response.failed\",\"response\":{\"id\":\"resp_fail\",\"status\":\"failed\",\"output\":[]}}",
  ])
  let turns : Array[Array[@posoco.Message]] = [[wsr_user_message("fail")]]
  let (results, _loopback) = wsr_chat_stream([sse], turns, "wsr-fail")
  guard results[0] is Err(@posoco.ModelError::Transport(message)) else {
    fail("a terminal provider failure must raise Transport")
  }
  assert_true(message.contains("stage=response.failed"))
  let ops = wsr_web_search_ops(events, "wsr-fail")
  assert_eq(ops.length(), 2)
  guard ops[0] is @kit_events.StatusOp::Register(segment~, value~, ..) else {
    fail("the search must announce its activity before failing")
  }
  assert_true(segment.contains("wsr-fail"))
  assert_eq(value, Some("searching"))
  assert_eq(ops[1], @kit_events.StatusOp::Unregister(segment~))
}

///|
#cfg(target="native")
async test "web search DONE without authoritative completion rejects partial state" {
  let sse = wsr_sse([
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"web_search_call\",\"id\":\"ws_partial\",\"status\":\"completed\",\"action\":{\"type\":\"search\",\"query\":\"partial\"}}}",
    "{\"type\":\"response.output_text.delta\",\"output_index\":1,\"delta\":\"answer\"}",
    "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"message\",\"id\":\"msg_partial\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}}",
    "[DONE]",
  ])
  let (results, _) = wsr_chat_stream(
    [sse],
    [[wsr_user_message("partial")]],
    "wsr-partial",
  )
  guard results[0] is Err(@posoco.ModelError::ResponseParse(message)) else {
    fail("DONE must not install hosted history without response.completed")
  }
  assert_true(message.contains("terminal"))
}

///|
#cfg(target="native")
async test "web search refuses streamed text missing from raw replay output" {
  let sse = wsr_sse([
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"web_search_call\",\"id\":\"ws_missing\",\"status\":\"completed\",\"action\":{\"type\":\"search\",\"query\":\"partial\"}}}",
    "{\"type\":\"response.output_text.delta\",\"output_index\":1,\"delta\":\"answer\"}",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_missing\",\"status\":\"completed\",\"output\":[]}}",
  ])
  let (results, _) = wsr_chat_stream(
    [sse],
    [[wsr_user_message("missing")]],
    "wsr-missing",
  )
  guard results[0] is Err(@posoco.ModelError::ResponseParse(message)) else {
    fail("must not return an answer whose original message cannot be replayed")
  }
  assert_true(message.contains("output.message"))
}

///|
/// An `annotation.added` event that omits `content_index` cannot say which text
/// part it annotates, so it may only name the first part. Treating it as a
/// wildcard would put a later part's words under this source.
#cfg(target="native")
async test "web search annotation without content index binds to the first part only" {
  let first = wsr_citation(0, 5, "https://example.com/first")
  let turns : Array[Array[@posoco.Message]] = [[wsr_user_message("two parts")]]
  let (results, _loopback) = wsr_chat_stream(
    [
      wsr_multipart_events(
        ["first part", "second"],
        [(0, first)],
        inline=false,
        with_content_index=false,
      ),
    ],
    turns,
    "wsr-noindex",
  )
  guard results[0] is Ok(result) else {
    fail("the citation turn must complete")
  }
  assert_eq(
    wsr_text(result.completion),
    "[first](https://example.com/first) partsecond",
  )
}

///|
/// A `done` snapshot may omit `output_index`, which makes an item's array
/// position differ from the wire index the annotation event states. The event
/// names the item it annotates, so that identity decides the binding and the
/// coordinates stay the fallback.
#cfg(target="native")
async test "web search citation binds by provider item id when done omits the index" {
  let item = "{\"type\":\"message\",\"id\":\"msg_ids\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer text\"}]}"
  let sse = wsr_sse([
    "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"answer text\"}",
    // The wire index is 3; the item is the only captured output item, so its
    // array position is 0. Only the item id ties the two together.
    "{\"type\":\"response.output_text.annotation.added\",\"item_id\":\"msg_ids\",\"output_index\":3,\"content_index\":0,\"annotation\":" +
    wsr_citation(0, 6, "https://example.com/ids") +
    "}",
    "{\"type\":\"response.output_item.done\",\"item\":" + item + "}",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_ids\",\"status\":\"completed\",\"output\":[" +
    item +
    "]}}",
  ])
  let turns : Array[Array[@posoco.Message]] = [[wsr_user_message("ids")]]
  let (results, _loopback) = wsr_chat_stream([sse], turns, "wsr-item-id")
  guard results[0] is Ok(result) else {
    fail("the citation turn must complete")
  }
  assert_eq(
    wsr_text(result.completion),
    "[answer](https://example.com/ids) text",
  )
}

///|
/// Several sources may cite the same words: the first keeps the words as its
/// label and the others are cited beside it, so no source is lost and the body
/// text is never repeated. An exact `(span, url)` repeat stays one citation.
#cfg(target="native")
async test "web search overlapping sources are kept beside the first link" {
  let primary = "https://example.com/one"
  let turns : Array[Array[@posoco.Message]] = [[wsr_user_message("same words")]]
  let (results, _loopback) = wsr_chat_stream(
    [
      wsr_answer_events("cited words here", [
        wsr_citation(0, 11, primary),
        wsr_citation(0, 11, "https://example.com/two"),
        // The same span and URL again: one citation, not two.
        wsr_citation(0, 11, primary),
      ]),
    ],
    turns,
    "wsr-overlap",
  )
  guard results[0] is Ok(result) else {
    fail("the overlapping citation turn must complete")
  }
  assert_eq(
    wsr_text(result.completion),
    "[cited words](https://example.com/one)[source](https://example.com/two) here",
  )
}

///|
#cfg(target="native")
async test "web search does not persist an unfinished added snapshot" {
  let sse = wsr_sse([
    "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"web_search_call\",\"id\":\"ws_unfinished\",\"status\":\"in_progress\"}}",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_unfinished\",\"status\":\"completed\",\"output\":[]}}",
  ])
  let (results, _) = wsr_chat_stream(
    [sse],
    [[wsr_user_message("unfinished")]],
    "wsr-unfinished",
  )
  guard results[0] is Err(@posoco.ModelError::ResponseParse(message)) else {
    fail("an in_progress search snapshot cannot become replayable history")
  }
  assert_true(message.contains("web_search_call.status"))
}
