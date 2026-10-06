///|
test "hello codec round-trips" {
  let frame = BoardClientFrame::Hello({
    last_seq: 0L,
    protocol_version: protocol_version(),
    has_board_snapshot: true,
  })
  match decode_client_frame(encode_client_frame(frame)) {
    Ok(decoded) => assert_eq(decoded, frame)
    Err(_) => fail("unexpected decode error")
  }
}

///|
test "legacy hello without baseline capability fails safe to false" {
  let raw = Json::object({
    "type": Json::string("hello"),
    "last_seq": Json::number(17),
    "protocol_version": Json::number(protocol_version().to_double()),
  }).stringify()
  assert_eq(
    decode_client_frame(raw),
    Ok(Hello({
      last_seq: 17L,
      protocol_version: protocol_version(),
      has_board_snapshot: false,
    })),
  )
  let invalid = Json::object({
    "type": Json::string("hello"),
    "last_seq": Json::number(17),
    "protocol_version": Json::number(protocol_version().to_double()),
    "has_board_snapshot": Json::string("yes"),
  }).stringify()
  assert_true(decode_client_frame(invalid) is Err(InvalidFrame(_)))
}

///|
test "command codec round-trips" {
  let frame = BoardClientFrame::Command({
    command_id: "c-1",
    name: "runtime.ping",
    expected_revision: 7L,
    args: Json::object({}),
  })
  match decode_client_frame(encode_client_frame(frame)) {
    Ok(decoded) => assert_eq(decoded, frame)
    Err(_) => fail("unexpected decode error")
  }
}

///|
test "server frames round-trip" {
  let frames : Array[BoardServerFrame] = [
    CommandResult({
      command_id: "c-1",
      accepted: true,
      error: None,
      current_revision: Some(9L),
    }),
    Event({
      seq: 13L,
      board_revision: 9L,
      kind: "runtime.ping",
      scope: Some({
        session_id: Some("s-1"),
        run_id: Some("r-1"),
        turn_id: Some("t-1"),
      }),
      payload: Json::object({ "ok": Json::boolean(true) }),
    }),
    Snapshot({
      protocol_version: protocol_version(),
      last_seq: 13L,
      board_revision: 9L,
      payload: Json::object({}),
    }),
  ]
  for frame in frames {
    match decode_server_frame(encode_server_frame(frame)) {
      Ok(decoded) => assert_eq(decoded, frame)
      Err(_) => fail("unexpected decode error")
    }
  }
}

///|
test "malformed client frame is rejected" {
  match decode_client_frame("{not-json") {
    Err(InvalidJson(_)) => ()
    Err(_) => fail("expected InvalidJson")
    Ok(_) => fail("malformed JSON must be rejected")
  }
  match decode_client_frame("{\"type\":\"command\"}") {
    Err(InvalidFrame(_)) => ()
    Err(_) => fail("expected InvalidFrame")
    Ok(_) => fail("incomplete command must be rejected")
  }
}

///|
test "unsupported hello protocol version is rejected" {
  let raw = Json::object({
    "type": Json::string("hello"),
    "last_seq": Json::number(0),
    "protocol_version": Json::number(2),
  }).stringify()
  match decode_client_frame(raw) {
    Err(UnsupportedVersion(expected~, got~)) => {
      assert_eq(expected, protocol_version())
      assert_eq(got, 2)
    }
    Err(_) => fail("expected UnsupportedVersion")
    Ok(_) => fail("future protocol version must be rejected")
  }
}

///|
test "event encoding keeps seq and board_revision as separate fields" {
  let frame = BoardServerFrame::Event({
    seq: 41L,
    board_revision: 3L,
    kind: "assistant.delta",
    scope: None,
    payload: Json::string("x"),
  })
  let raw = encode_server_frame(frame)
  let parsed = @json.parse(raw)
  match parsed {
    Json::Object(fields) => {
      assert_eq(fields.get("seq"), Some(Json::number(41)))
      assert_eq(fields.get("board_revision"), Some(Json::number(3)))
    }
    _ => fail("encoded event must be an object")
  }
}
