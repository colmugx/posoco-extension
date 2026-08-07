///|
test "handoff_state/json_round_trip" {
  let original : HandoffState = {
    version: 1,
    generation: 3,
    id: "handoff-3-source",
    status: Offered,
    source_session_id: "source",
    target_session_id: None,
    rejected_by_session_id: None,
    rejection_reason: None,
    workspace: {
      root: "/repo",
      branch: Some("main"),
      head: Some("abc123"),
      signature: "sig",
      changed_files: ["src/a.mbt", "README.md"],
    },
    work: {
      objective: Some("Implement handoff"),
      current_step: Some("Wire command context"),
      next_action: Some("Run tests"),
      completed: ["protocol types"],
      pending: ["Cetas integration"],
      validation_passed: ["codec test"],
      validation_failed: [],
      validation_not_run: ["moon test"],
    },
  }
  let json = @json.parse(original.stringify()) catch {
    _ => fail("generated handoff state must be valid JSON")
  }
  match handoff_state_from_json(json) {
    Ok(decoded) => assert_eq(decoded, original)
    Err(reason) => fail("round trip failed: " + reason)
  }
}

///|
test "handoff_state/rejects_unknown_status" {
  let json = @json.parse(
    "{\"version\":1,\"generation\":1,\"id\":\"h\",\"status\":\"mystery\",\"source_session_id\":\"s\",\"workspace\":{\"root\":\"/r\",\"signature\":\"x\",\"changed_files\":[]},\"work\":{}}",
  ) catch {
    _ => fail("fixture must be valid JSON")
  }
  match handoff_state_from_json(json) {
    Err(reason) => assert_true(reason.contains("status"))
    Ok(_) => fail("unknown status must not be accepted")
  }
}
