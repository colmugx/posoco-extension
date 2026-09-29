///|
fn projection_call() -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("call/α"),
    name: @posoco.ToolName::unchecked("read"),
    arguments: { "path": "RAW_ARGUMENT_SENTINEL" },
  }
}

///|
fn projection_message() -> @posoco.Message {
  @posoco.Message::AssistantMessage(
    content=[Text("RAW_MESSAGE_SENTINEL")],
    tool_calls=[],
    reasoning=None,
    finish_reason=Stop,
  )
}

///|
fn projection_scope(suffix : String) -> @posoco.EventScope {
  {
    session_id: @posoco.SessionId::unchecked("session/" + suffix),
    run_id: @posoco.RunId::unchecked("run/" + suffix),
    turn_id: @posoco.TurnId::unchecked("turn/" + suffix),
  }
}

///|
test "board projection all mappings preserve order seq and zero revision without IO" {
  let server : CommandFakeServer = { binds: 0, alive: false, }
  let opener : CommandFakeOpener = { urls: [], }
  let runtime = @runtime.BoardRuntime::with_adapters(server~, opener~)
  let board = BoardExtension::with_runtime(runtime~)
  let call = projection_call()
  let cases : Array[(@posoco.TurnEvent, String, Json)] = [
    (TurnStarted, "run.started", {}),
    (
      StreamChunkReceived(chunk=TextDelta(token="hello")),
      "assistant.delta",
      { "text": "hello" },
    ),
    (
      StreamChunkReceived(chunk=ReasoningDelta(token="thinking")),
      "assistant.reasoning_delta",
      { "text": "thinking" },
    ),
    (
      ToolCallPending(call),
      "tool.pending",
      { "call_id": "call/α", "tool": "read", "preview": "Pending" },
    ),
    (
      ToolCallSucceeded(
        call~,
        content="done",
        structured=Some({ "raw": "STRUCTURED_SENTINEL" }),
        attachments=[Text("ATTACHMENT_SENTINEL")],
      ),
      "tool.completed",
      { "call_id": "call/α", "tool": "read", "preview": "done" },
    ),
    (
      ToolCallFailed(
        call~,
        failure=Runtime(category="PROVIDER_SENTINEL", message="ERROR_SENTINEL"),
      ),
      "tool.failed",
      { "call_id": "call/α", "tool": "read", "preview": "Failed" },
    ),
    (
      ToolCallFailed(
        call~,
        failure=ReportedError(
          content="ERROR_SENTINEL",
          structured=Some({ "raw": "STRUCTURED_SENTINEL" }),
        ),
      ),
      "tool.failed",
      { "call_id": "call/α", "tool": "read", "preview": "Failed" },
    ),
    (
      ToolCallRejected(
        call~,
        reason=RejectedByHook(reason="REJECTION_SENTINEL"),
      ),
      "tool.failed",
      { "call_id": "call/α", "tool": "read", "preview": "Rejected" },
    ),
    (
      ToolCallAbandoned(call~, reason="ABANDONED_SENTINEL"),
      "tool.failed",
      { "call_id": "call/α", "tool": "read", "preview": "Abandoned" },
    ),
    (
      ModelResponseReceived(message=projection_message(), usage=None),
      "model.response",
      { "usage": Json::null() },
    ),
    (
      UserRequestStarted(kind="confirm", prompt="Continue?"),
      "run.blocked",
      { "kind": "confirm", "prompt": "Continue?" },
    ),
    (
      UserRequestFinished(kind="confirm", outcome="answered"),
      "run.resumed",
      { "kind": "confirm", "outcome": "answered" },
    ),
    (
      StreamChunksDropped(count=3),
      "runtime.warning",
      { "code": "stream_chunks_dropped", "count": 3 },
    ),
    (
      ConfigWarning(
        field="FIELD_SENTINEL",
        value="VALUE_SENTINEL",
        reason="REASON_SENTINEL",
      ),
      "runtime.warning",
      {
        "code": "config_warning",
        "preview": "Configuration could not be applied",
      },
    ),
    (TurnCompleted, "run.completed", {}),
    (
      TurnFailed("PROVIDER_ERROR_SENTINEL"),
      "run.failed",
      { "preview": "Run failed" },
    ),
  ]
  let scope = projection_scope("α")
  let observer = board.manifest().observers[0]
  for entry in cases {
    observer.on_event_at(Some(scope), entry.0)
  }
  let history = runtime.event_history()
  assert_eq(history.length(), cases.length())
  for i, event in history {
    assert_eq(event.kind, cases[i].1)
    assert_eq(event.payload, cases[i].2)
    assert_eq(event.seq, (i + 1).to_int64())
    assert_eq(event.board_revision, 0L)
    assert_eq(
      event.scope,
      Some(@protocol.BoardEventScope::{
        session_id: Some("session/α"),
        run_id: Some("run/α"),
        turn_id: Some("turn/α"),
      }),
    )
    assert_false(event.payload.stringify().contains("SENTINEL"))
  }
  // Unattributed versions of every mapping stay unattributed even after a run.
  for entry in cases {
    observer.on_event_at(None, entry.0)
  }
  let unscoped = runtime.event_history()
  for i in 0..<cases.length() {
    let event = unscoped[cases.length() + i]
    assert_eq(event.scope, None)
    assert_eq(event.kind, cases[i].1)
    assert_eq(event.payload, cases[i].2)
    assert_eq(event.board_revision, 0L)
    assert_eq(event.seq, (cases.length() + i + 1).to_int64())
  }
  assert_eq(runtime.current_seq(), (cases.length() * 2).to_int64())
  assert_eq(server.binds, 0)
  assert_false(server.alive)
  assert_eq(opener.urls.length(), 0)
}

///|
test "board projection never guesses scope and unscoped observer delegates" {
  let board = BoardExtension::BoardExtension()
  let a = projection_scope("a")
  let b = projection_scope("b")
  board.on_event_at(Some(a), TurnStarted)
  board.on_event_at(
    None,
    StreamChunkReceived(chunk=TextDelta(token="unattributed")),
  )
  board.on_event_at(Some(b), TurnStarted)
  board.on_event_at(Some(a), TurnCompleted)
  board.on_event(TurnFailed("opaque"))
  board.on_event_at(None, ConfigWarning(field="x", value="y", reason="z"))
  let events = board.runtime().event_history()
  assert_eq(events.length(), 6)
  assert_eq(events[0].scope, board_scope(Some(a)))
  assert_eq(events[1].scope, None)
  assert_eq(events[2].scope, board_scope(Some(b)))
  assert_eq(events[3].scope, board_scope(Some(a)))
  assert_eq(events[4].scope, None)
  assert_eq(events[5].scope, None)
}

///|
test "board projection usage preserves unknown zero and provider totals" {
  let board = BoardExtension::BoardExtension()
  let usage : @posoco.Usage = {
    input_tokens: Some(0),
    output_tokens: Some(7),
    total_tokens: None,
    cached_input_tokens: None,
    uncached_input_tokens: Some(0),
  }
  board.on_event(
    ModelResponseReceived(message=projection_message(), usage=Some(usage)),
  )
  board.on_event(
    ModelResponseReceived(
      message=projection_message(),
      usage=Some({
        input_tokens: None,
        output_tokens: None,
        total_tokens: None,
        cached_input_tokens: None,
        uncached_input_tokens: None,
      }),
    ),
  )
  board.on_event(
    ModelResponseReceived(
      message=projection_message(),
      usage=Some({
        input_tokens: Some(8),
        output_tokens: Some(7),
        total_tokens: Some(99),
        cached_input_tokens: Some(3),
        uncached_input_tokens: Some(5),
      }),
    ),
  )
  let events = board.runtime().event_history()
  assert_eq(events[0].payload, {
    "usage": {
      "input_tokens": 0,
      "output_tokens": 7,
      "total_tokens": Json::null(),
      "cached_input_tokens": Json::null(),
      "uncached_input_tokens": 0,
    },
  })
  assert_eq(events[1].payload, {
    "usage": {
      "input_tokens": Json::null(),
      "output_tokens": Json::null(),
      "total_tokens": Json::null(),
      "cached_input_tokens": Json::null(),
      "uncached_input_tokens": Json::null(),
    },
  })
  assert_eq(events[2].payload, {
    "usage": {
      "input_tokens": 8,
      "output_tokens": 7,
      "total_tokens": 99,
      "cached_input_tokens": 3,
      "uncached_input_tokens": 5,
    },
  })
}

///|
test "board projection credential lines redacted case insensitively before truncation" {
  for
    key in [
      "AuThOrIzAtIoN", "API_KEY", "ApiKey", "ACCESS_TOKEN", "Refresh_Token", "PaSsWoRd",
      "SeCrEt",
    ] {
    assert_eq(
      board_display("safe\nprefix " + key + ": private\nsafe again"),
      "safe\n[redacted]\nsafe again",
    )
    assert_eq(board_display(key + "=private\rtrailing"), "[redacted]")
  }
  let long = String::from_array(Array::make(1025, '界'))
  assert_eq(board_display(""), "")
  assert_eq(
    board_display(String::from_array(Array::make(1024, '界')))
    .to_array()
    .length(),
    1024,
  )
  let truncated = board_display(long)
  assert_eq(truncated.to_array().length(), 1024)
  assert_true(truncated.has_suffix("...[truncated]"))
  assert_eq(board_display(long + " API_KEY=private"), "[redacted]")
  assert_eq(board_display("🙂"), "🙂")
}

///|
test "board projection sanitizes every display surface and bounds previews" {
  let board = BoardExtension::BoardExtension()
  let long = String::from_array(Array::make(2000, 'x'))
  let sensitive = "Authorization: private"
  let call = {
    ..projection_call(),
    name: @posoco.ToolName::unchecked(sensitive),
  }
  board.on_event(
    ToolCallSucceeded(call~, content=long, structured=None, attachments=[]),
  )
  board.on_event(StreamChunkReceived(chunk=TextDelta(token=sensitive)))
  board.on_event(StreamChunkReceived(chunk=ReasoningDelta(token=sensitive)))
  board.on_event(UserRequestStarted(kind=sensitive, prompt=sensitive))
  board.on_event(UserRequestFinished(kind=sensitive, outcome=sensitive))
  board.on_event(
    ToolCallSucceeded(call~, content=sensitive, structured=None, attachments=[]),
  )
  let events = board.runtime().event_history()
  assert_eq(events[0].payload, {
    "call_id": "call/α",
    "tool": "[redacted]",
    "preview": board_display(long),
  })
  assert_eq(events[1].payload, { "text": "[redacted]" })
  assert_eq(events[2].payload, { "text": "[redacted]" })
  assert_eq(events[3].payload, { "kind": "[redacted]", "prompt": "[redacted]" })
  assert_eq(events[4].payload, { "kind": "[redacted]", "outcome": "[redacted]" })
  assert_eq(events[5].payload, {
    "call_id": "call/α",
    "tool": "[redacted]",
    "preview": "[redacted]",
  })
}

///|
test "board projection ignored events do not mint seq or duplicate tool success" {
  let board = BoardExtension::BoardExtension()
  let call = projection_call()
  board.on_event(TurnStarted)
  let ignored : Array[@posoco.TurnEvent] = [
    ToolCallApproved(call~, consent_scope=Some("private")),
    ToolCallStarted(call~),
    StreamChunkReceived(
      chunk=ToolCallDelta(
        index=0,
        id=None,
        name=None,
        arguments_delta=Some("private"),
      ),
    ),
    StreamChunkReceived(chunk=Finish(reason="stop")),
    StreamChunkReceived(
      chunk=Usage(
        input_tokens=1,
        output_tokens=2,
        total_tokens=3,
        cached_input_tokens=None,
        uncached_input_tokens=None,
      ),
    ),
    Custom(source="private", label="private", data={ "raw": "private" }),
    ConfigChanged(field="private", old_value="private", new_value="private"),
  ]
  for event in ignored {
    board.on_event(event)
  }
  assert_eq(board.runtime().current_seq(), 1L)
  board.on_event(
    ToolCallSucceeded(call~, content="done", structured=None, attachments=[]),
  )
  board.on_event(TurnCompleted)
  let events = board.runtime().event_history()
  assert_eq(events.length(), 3)
  assert_eq(events[1].kind, "tool.completed")
  assert_eq(events[2].seq, 3L)
  for event in events {
    assert_eq(event.board_revision, 0L)
  }
  assert_eq(board.manifest().hooks.length(), 0)
}

///|
test "board projection input budget omits oversized text without leaking a prefix" {
  let boundary = String::from_array(Array::make(16384, 'x'))
  assert_eq(boundary.length(), 16384)
  assert_eq(board_display(boundary).to_array().length(), 1024)
  assert_true(board_display(boundary).has_suffix("...[truncated]"))
  assert_eq(board_display(boundary + "x"), "[truncated]")
  // The guard counts UTF-16 units, not Unicode characters.
  let astral = String::from_array(Array::make(8192, '🙂'))
  assert_eq(astral.length(), 16384)
  assert_eq(board_display(astral).to_array().length(), 1024)
  assert_eq(board_display(astral + "x"), "[truncated]")
  let credential_tail = " API_KEY=private"
  let in_budget = String::from_array(
      Array::make(16384 - credential_tail.length(), 'x'),
    ) +
    credential_tail
  assert_eq(board_display(in_budget), "[redacted]")
  assert_eq(board_display(in_budget + "x"), "[truncated]")
  let multiline = Array::make(100000, "innocent\n").join("")
  assert_eq(board_display(multiline), "[truncated]")
  assert_eq(
    board_display("private prefix " + multiline + credential_tail),
    "[truncated]",
  )
  // Even an input that would shrink to empty must fail the initial budget gate.
  assert_eq(
    board_display(String::from_array(Array::make(16385, '\u0000'))),
    "[truncated]",
  )
  let board = BoardExtension::BoardExtension()
  board.on_event(StreamChunkReceived(chunk=TextDelta(token=multiline)))
  assert_eq(board.runtime().event_history()[0].payload, {
    "text": "[truncated]",
  })
}

///|
test "board projection strips unsafe controls before redaction without damaging ordinary text" {
  let controls : Array[Char] = []
  for code in 0..<32 {
    if code != 9 && code != 10 {
      controls.push(code.unsafe_to_char())
    }
  }
  for code in 0x7F..<0xA0 {
    controls.push(code.unsafe_to_char())
  }
  for code in 0x202A..<0x202F {
    controls.push(code.unsafe_to_char())
  }
  for code in 0x2066..<0x206A {
    controls.push(code.unsafe_to_char())
  }
  for control in controls {
    let text = control.to_string()
    assert_eq(board_display("left" + text + "right"), "leftright")
    assert_eq(board_display("API_" + text + "KEY=private"), "[redacted]")
  }
  assert_eq(board_display(String::from_array(controls)), "")
  let input = "hello\u0000\u001B world\r\n\t界🙂\u007F\u009F\u202Eend\u2069"
  let expected = "hello world\n\t界🙂end"
  assert_eq(board_display(input), expected)
  assert_eq(board_display(" \t\n~\u00A0界🙂"), " \t\n~\u00A0界🙂")
  let board = BoardExtension::BoardExtension()
  board.on_event(StreamChunkReceived(chunk=ReasoningDelta(token=input)))
  assert_eq(board.runtime().event_history()[0].payload, { "text": expected })
}
