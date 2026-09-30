///|
test "resync and tiny error codecs round trip" {
  let frames : Array[BoardServerFrame] = [
    ResyncRequired(reason="client_queue_overflow", current_seq=3L),
    Error(code="hello_required", message="First frame must be Hello"),
  ]
  for frame in frames {
    assert_eq(decode_server_frame(encode_server_frame(frame)), Ok(frame))
  }
  assert_eq(@json.parse(encode_server_frame(frames[0])), {
    "type": "resync_required",
    "reason": "client_queue_overflow",
    "current_seq": 3,
  })
  assert_eq(@json.parse(encode_server_frame(frames[1])), {
    "type": "error",
    "code": "hello_required",
    "message": "First frame must be Hello",
  })
  for
    raw in [
      "{\"type\":\"resync_required\",\"reason\":\"x\"}", "{\"type\":\"error\",\"code\":\"x\"}",
    ] {
    assert_true(decode_server_frame(raw) is Err(InvalidFrame(_)))
  }
}

///|
test "hello rejects fractional negative unsafe cursors and wrapping versions" {
  for cursor in ["-1", "0.5", "9007199254740992", "1e100", "null", "\"1\""] {
    let raw = "{\"type\":\"hello\",\"last_seq\":" +
      cursor +
      ",\"protocol_version\":1}"
    assert_true(decode_client_frame(raw) is Err(InvalidFrame(_)))
  }
  for version in ["-1", "1.5", "4294967297", "9007199254740992"] {
    let raw = "{\"type\":\"hello\",\"last_seq\":0,\"protocol_version\":" +
      version +
      "}"
    assert_true(decode_client_frame(raw) is Err(_))
  }
}
