///|
fn expect_invalid(run : () -> Unit raise) -> Unit raise {
  try run() catch {
    @protocol.ProtocolError::Invalid(_) => ()
    error => fail("unexpected error: " + error.to_string())
  } noraise {
    _ => fail("expected protocol rejection")
  }
}

///|
test "invalid encoding, oversized frames and partial EOF are rejected" {
  expect_invalid(() => ignore(@protocol.Decoder().feed(b"\xff\n")))
  expect_invalid(() => ignore(@protocol.Decoder().feed(b"not-json\n")))
  expect_invalid(() => ignore(@protocol.Decoder(max_frame_bytes=2).feed(b"123")))
  let decoder = @protocol.Decoder()
  ignore(decoder.feed(b"{}"))
  expect_invalid(() => decoder.finish())
}

///|
test "requests must be correlated and finished before final result" {
  let session = @protocol.HostSession(max_pending=1, max_calls=2)
  ignore(session.receive(@protocol.Hello(protocol=1)))
  ignore(session.receive(@protocol.Request(id=1, name="read", arguments={})))
  expect_invalid(() => {
    ignore(session.receive(@protocol.Request(id=1, name="read", arguments={})))
  })
  expect_invalid(() => {
    ignore(session.receive(@protocol.Request(id=2, name="read", arguments={})))
  })
  let outcome = @protocol.Success(
    content="ok",
    structured=Some({ "value": 42 }),
  )
  expect_invalid(() => ignore(session.receive(@protocol.Result(outcome~))))
  expect_invalid(() => ignore(session.reply(9, outcome)))
  ignore(session.reply(1, outcome))
  ignore(session.receive(@protocol.Result(outcome~)))
  expect_invalid(() => ignore(session.receive(@protocol.Result(outcome~))))
  assert_eq(session.finish(0), outcome)
  expect_invalid(() => ignore(session.finish(0)))
}

///|
test "normal exit without result and version skew fail closed" {
  expect_invalid(() => ignore(@protocol.HostSession().finish(0)))
  expect_invalid(() => {
    ignore(@protocol.HostSession().receive(@protocol.Hello(protocol=2)))
  })
  let session = @protocol.HostSession()
  ignore(session.receive(@protocol.Hello(protocol=1)))
  ignore(
    session.receive(
      @protocol.Result(outcome=@protocol.Success(content="ok", structured=None)),
    ),
  )
  expect_invalid(() => ignore(session.finish(1)))
}

///|
test "outcomes preserve failure category and structured content" {
  let outcome = @protocol.Failure(
    code="denied",
    content="not authorized",
    structured=Some({ "tool": "write" }),
  )
  let message = @protocol.Reply(id=7, outcome~)
  assert_eq(@protocol.Message::from_json(message.to_json()), message)
  expect_invalid(() => {
    ignore(
      @protocol.Message::from_json({
        "type": "request",
        "id": 1.5,
        "name": "read",
        "arguments": {},
      }),
    )
  })
}
