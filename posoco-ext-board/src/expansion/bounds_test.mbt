///|
test "decoder rejects duplicate local references and whitespace-only descriptions" {
  assert_true(
    decode(payload(tasks=[task_json("same"), task_json("same")]))
    is Err(@expansion.InvalidString(..)),
  )
  assert_true(
    decode(payload().replace(old="Plan only", new="  "))
    is Err(@expansion.InvalidString(..)),
  )
  assert_true(decode(payload().replace(old="Plan only", new="")) is Ok(_))
}

///|
fn chain_payload(count : Int32, external~ : Bool = false) -> String {
  let tasks = Array::makei(count, index => {
    let dependencies : Json = if index == 0 {
      if external {
        [{ "existing": "parent" }]
      } else {
        []
      }
    } else {
      [{ "local": "node-\{index - 1}" }]
    }
    task_json("node-\{index}", dependencies~)
  })
  payload(tasks~)
}

///|
async test "graph depth budget includes existing dependencies and rejects before allocation" {
  @async.with_task_group(group => {
    let backend = board(group)
    let before = backend.state().unwrap()
    for
      (count, external, accepted) in [
        (16, false, true),
        (17, false, false),
        (15, true, true),
        (16, true, false),
      ] {
      let allocator : CountingAllocator = { calls: 0, }
      let host = @expansion.ExpansionHost(backend~, allocator~, now_ms=() => {
        100L
      })
      let result = host.prepare(
        chain_payload(count, external~),
        authorization=Some(authority()),
      )
      if accepted {
        assert_true(result is Ok(_))
      } else {
        assert_true(
          result is Err(@expansion.PolicyBudgetExceeded("graph depth budget")),
        )
        assert_true(host.preview() is Err(@expansion.InvalidPhase))
      }
      assert_eq(allocator.calls, 0)
      assert_eq(backend.state().unwrap(), before)
    }
    backend.shutdown()
  })
}

///|
async test "authorization never widens zero negative or excessive numeric budgets" {
  @async.with_task_group(group => {
    let backend = board(group)
    let before = backend.state().unwrap()
    for (tasks, edges) in [(0, 0), (-1, 1), (21, 1), (1, -1), (1, 61)] {
      let host = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
      assert_true(
        host.prepare(payload(), authorization=Some(authority(tasks~, edges~)))
        is Err(@expansion.InvalidAuthorization("invalid budgets")),
      )
      assert_eq(backend.state().unwrap(), before)
    }
    backend.shutdown()
  })
}
