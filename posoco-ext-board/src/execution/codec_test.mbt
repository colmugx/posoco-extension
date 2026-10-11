///|
fn reserved() -> @execution.BoardExecutionBinding {
  {
    task_id: "task",
    attempt_id: "attempt",
    execution_id: "exec",
    session_id: "session",
    run: None,
    phase: @execution.Reserved,
    outcome: None,
  }
}

///|
test "versioned execution journal round trips phases outcomes and contains metadata only" {
  for
    phase in [
      @execution.Reserved,
      @execution.Running,
      @execution.Finished,
      @execution.Settled,
      @execution.Unresolved,
    ] {
    for
      outcome in [
        @execution.Completed,
        @execution.Failed,
        @execution.Cancelled,
        @execution.TimedOut,
        @execution.Interrupted,
      ] {
      let binding : @execution.BoardExecutionBinding = {
        ..reserved(),
        phase,
        run: if phase == @execution.Reserved {
          None
        } else {
          Some({ session_id: "session", run_id: "run", turn_id: "turn", })
        },
        outcome: if phase == @execution.Reserved || phase == @execution.Running {
          None
        } else {
          Some(outcome)
        },
      }
      let encoded = @execution.encode_execution_journal([binding]).unwrap()
      assert_eq(@execution.decode_execution_journal(encoded), Ok([binding]))
      assert_false(encoded.contains("input"))
      assert_false(encoded.contains("messages"))
      assert_false(encoded.contains("credentials"))
    }
  }
}

///|
test "journal strict parsing fails closed on schema corruption unknown fields invalid identities and phases" {
  let valid = @execution.encode_execution_journal([reserved()]).unwrap()
  for
    invalid in [
      "",
      "[]",
      "null",
      "{\"schema_version\":1}",
      valid.replace(old="\"schema_version\":1", new="\"schema_version\":2"),
      valid.replace(old="\"schema_version\":1", new="\"schema_version\":null"),
      valid.replace(old="\"reserved\"", new="\"unknown\""),
      valid.replace(old="\"reserved\"", new="\"running\""),
      valid.replace(old="\"reserved\"", new="\"settled\""),
      valid.replace(old="\"attempt\"", new="\" \""),
      valid.replace(old="\"task\"", new="null"),
      valid.replace(
        old="\"run\":null",
        new="\"run\":{\"session_id\":\"other\",\"run_id\":\"r\",\"turn_id\":\"t\"}",
      ),
      valid.replace(old="\"outcome\":null", new="\"outcome\":\"completed\""),
      valid.replace(old="\"outcome\":null", new="\"outcome\":\"unknown\""),
      valid.replace(
        old="\"outcome\":null",
        new="\"outcome\":null,\"input\":\"secret\"",
      ),
      valid.replace(
        old="\"schema_version\":1",
        new="\"extra\":true,\"schema_version\":1",
      ),
    ] {
    assert_true(
      @execution.decode_execution_journal(invalid)
      is Err(@execution.StoreUnavailable),
    )
  }
  assert_true(
    @execution.encode_execution_journal([reserved(), reserved()])
    is Err(@execution.StoreUnavailable),
  )
  assert_true(
    @execution.encode_execution_journal([{ ..reserved(), session_id: "", }])
    is Err(@execution.StoreUnavailable),
  )
}

///|
async test "memory journal and owner inspection detach collection ownership" {
  let store = @execution.MemoryBoardExecutionStore()
  let source = [reserved()]
  assert_true(store.persist(source) is Ok(_))
  source.clear()
  let returned = store.load().unwrap()
  returned.clear()
  assert_eq(store.load(), Ok([reserved()]))
}
