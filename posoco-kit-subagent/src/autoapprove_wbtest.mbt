///|
fn approval_request(tool : String) -> @permission.ApprovalRequest {
  {
    tool_name: tool,
    call_id: "call_1",
    category: "write",
    arguments_preview: "{}",
    arguments: Json::empty_object(),
  }
}

///|
async test "autoapprove_always_answers_allowalways" {
  let source = AutoApprove::AutoApprove() as &@permission.ApprovalSource
  let first = source.ask(approval_request("write"))
  let second = source.ask(approval_request("bash"))
  match (first, second) {
    (
      @permission.ApprovalDecision::AllowAlways,
      @permission.ApprovalDecision::AllowAlways,
    ) => ()
    _ => fail("expected AllowAlways for every request")
  }
}
