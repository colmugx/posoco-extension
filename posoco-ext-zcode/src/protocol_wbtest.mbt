///|
/// Wire fixtures come from docs/fixtures/zcode-appserver-transcript.jsonl
/// (live zcode 0.16.5 session, `>>> `/`<<< ` prefixes stripped). The fixture
/// generator stripped the session/event envelope off event payloads, so the
/// two session/event lines are reconstructed per the documented envelope
/// `{"method":"session/event","params":{"type":...}}`.

///|
test "decode_server_reverse_request_with_string_id" {
  let line =
    #|{"id": "server-1", "method": "interaction/requestOfficialMcpAuthHeaders", "params": {"mcpKey": "image_search", "pluginId": "document-skills@zcode-plugins-official", "requestId": "official-mcp-auth:1", "targetOrigin": "https://zcode.z.ai", "workspace": {"workspaceKey": "/tmp/zprobe2", "workspacePath": "/tmp/zprobe2"}}}
  match zcode_wire_decode(line) {
    Ok(Request(id~, method_name~, params~)) => {
      assert_true(id == Json::string("server-1"))
      assert_eq(method_name, "interaction/requestOfficialMcpAuthHeaders")
      assert_eq(
        json_field_string(params.unwrap(), "mcpKey").unwrap(),
        "image_search",
      )
    }
    Ok(_) => fail("expected a Request")
    Err(message) => fail(message)
  }
}

///|
test "decode_response_with_result_and_numeric_id" {
  let line =
    #|{"id": 4, "result": {"accepted": true, "sessionId": "sess_16429dc7-7eaa-4c34-b2f6-72adc25c8637", "stateRevision": 1}}
  match zcode_wire_decode(line) {
    Ok(Response(id~, result~, error~)) => {
      assert_true(id == Json::number(4.0))
      assert_true(error is None)
      match result {
        Some(r) =>
          assert_true(json_field(r, "accepted") == Some(Json::boolean(true)))
        None => fail("expected a result object")
      }
    }
    Ok(_) => fail("expected a Response")
    Err(message) => fail(message)
  }
}

///|
test "decode_response_with_error_object" {
  let line =
    #|{"id": "server-9", "error": {"code": -32601, "message": "Method not found"}}
  match zcode_wire_decode(line) {
    Ok(Response(id~, result~, error~)) => {
      assert_true(id == Json::string("server-9"))
      assert_true(result is None)
      match error {
        Some(e) => {
          assert_eq(e.code, -32601)
          assert_eq(e.message, "Method not found")
          assert_true(e.data is None)
        }
        None => fail("expected an error object")
      }
    }
    Ok(_) => fail("expected a Response")
    Err(message) => fail(message)
  }
}

///|
test "decode_real_notification_line" {
  let line =
    #|{"method": "computer-use/operation-event", "params": {"eventId": "4900a826-fe0e-4b11-a960-95dffc0753ff", "sequenceNumber": 2, "sessionId": "sess_16429dc7-7eaa-4c34-b2f6-72adc25c8637", "timestamp": 1788536787612, "kind": "turn-started", "turnId": "turn_e2ece94f-b9ce-447c-9b64-056645692de8"}}
  match zcode_wire_decode(line) {
    Ok(Notification(method_name~, params~)) => {
      assert_eq(method_name, "computer-use/operation-event")
      assert_eq(
        json_field_string(params.unwrap(), "kind").unwrap(),
        "turn-started",
      )
    }
    Ok(_) => fail("expected a Notification")
    Err(message) => fail(message)
  }
}

///|
test "decode_session_event_envelopes_as_notifications" {
  let streaming =
    #|{"method": "session/event", "params": {"type": "model.streaming", "delta": "pong", "done": false, "kind": "text_delta"}}
  match zcode_wire_decode(streaming) {
    Ok(Notification(method_name~, params~)) => {
      assert_eq(method_name, "session/event")
      assert_eq(
        json_field_string(params.unwrap(), "type").unwrap(),
        "model.streaming",
      )
    }
    Ok(_) => fail("expected a Notification")
    Err(message) => fail(message)
  }
  let completed =
    #|{"method": "session/event", "params": {"type": "turn.completed", "response": "pong", "tokenCount": 28856, "usage": {"source": "provider", "inputTokens": 28853, "outputTokens": 3, "totalTokens": 28856}}}
  match zcode_wire_decode(completed) {
    Ok(Notification(method_name~, ..)) =>
      assert_eq(method_name, "session/event")
    Ok(_) => fail("expected a Notification")
    Err(message) => fail(message)
  }
}

///|
test "decode_malformed_lines_err" {
  let lines = ["not json", "", "[1, 2, 3]", "{\"foo\": 1}", "{\"id\": 1}"]
  for line in lines {
    match zcode_wire_decode(line) {
      Err(_) => ()
      Ok(_) => fail("expected Err for line: " + line)
    }
  }
}

///|
/// Real fixture line: the transcript generator stripped the session/event
/// envelope, leaving a bare payload with neither method nor id — the wire
/// classifier must reject it instead of guessing.
test "decode_id_less_payload_errs" {
  let line =
    #|{"previousTitle": "", "source": "first_input", "title": "Request for single word pong reply"}
  match zcode_wire_decode(line) {
    Err(_) => ()
    Ok(_) => fail("expected Err for a bare event payload")
  }
}

///|
test "to_line_round_trip_preserves_request" {
  let line =
    #|{"id": 2, "method": "session/create", "params": {"workspace": {"workspacePath": "/tmp/zprobe2", "workspaceKey": "/tmp/zprobe2"}, "mode": "edit"}}
  match zcode_wire_decode(line) {
    Ok(wire) =>
      match zcode_wire_decode(wire.to_line()) {
        Ok(again) => assert_true(wire == again)
        Err(message) => fail(message)
      }
    Err(message) => fail(message)
  }
}

///|
test "to_line_of_constructed_request_round_trips" {
  let wire = Request(
    id=Json::number(7.0),
    method_name="session/subscribe",
    params=Some(
      Json::object(
        Map::from_array([
          ("sessionId", Json::string("sess_abc")),
          ("afterSeq", Json::number(0.0)),
        ]),
      ),
    ),
  )
  match zcode_wire_decode(wire.to_line()) {
    Ok(Request(id~, method_name~, params~)) => {
      assert_true(id == Json::number(7.0))
      assert_eq(method_name, "session/subscribe")
      assert_eq(
        json_field_string(params.unwrap(), "sessionId").unwrap(),
        "sess_abc",
      )
    }
    Ok(_) => fail("expected a Request after round trip")
    Err(message) => fail(message)
  }
}
