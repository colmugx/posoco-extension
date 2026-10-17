///|
async test "C1 control characters are rejected by proposal authority and canonical allocation" {
  @async.with_task_group(group => {
    let backend = board(group)
    let before = backend.state().unwrap()
    for code in [0x7f, 0x80, 0x9c, 0x9f] {
      let control = code.unsafe_to_char().to_string()
      for
        text in [
          payload(proposal="p" + control),
          payload(tasks=[task_json("key" + control)]),
          payload(tasks=[task_json("a", description="text" + control)]),
          payload(tasks=[task_json("a", title="title" + control)]),
        ] {
        assert_true(decode(text) is Err(@expansion.InvalidString(..)))
      }
      let denied = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
      assert_true(
        denied.prepare(
          payload(),
          authorization=Some(authority(workflow="wf" + control)),
        )
        is Err(@expansion.InvalidAuthorization(_)),
      )
      let allocator : FixedAllocator = { id: "allocated" + control, }
      let host = @expansion.ExpansionHost(backend~, allocator~, now_ms=() => {
        100L
      })
      assert_true(
        host.prepare(payload(), authorization=Some(authority())) is Ok(_),
      )
      let approval = host
        .approve(host.preview().unwrap(), HostApprover::{ grant: true, })
        .unwrap()
      assert_true(host.commit(approval) is Err(@expansion.AllocationFailed))
      assert_eq(host.mapping(), [])
      assert_eq(backend.state().unwrap(), before)
    }
    assert_true(
      decode(payload().replace(old="proposal-1", new="p\\u009c"))
      is Err(@expansion.InvalidString(..)),
    )
    backend.shutdown()
  })
}

///|
async test "definitive pre-visibility store failure conflicts without uncertain replay" {
  @async.with_task_group(group => {
    let store : AmbiguousStore = {
      inner: @store.MemoryBoardStore(),
      mode: 0,
      writes: 0,
    }
    let backend = @backend.BoardBackend(store~, now_ms=() => 100L)
    backend.attach(group)
    create_parent(backend)
    let before = backend.state().unwrap()
    let host = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
    assert_true(
      host.prepare(payload(), authorization=Some(authority())) is Ok(_),
    )
    let approval = host
      .approve(host.preview().unwrap(), HostApprover::{ grant: true, })
      .unwrap()
    store.mode = 3
    assert_true(
      host.commit(approval)
      is Err(@expansion.Backend(@coordinator.PersistFailed(_))),
    )
    assert_eq(host.phase(), @expansion.Conflict)
    assert_eq(backend.state().unwrap(), before)
    assert_eq(store.inner.load().unwrap().snapshot, before)
    assert_eq(store.writes, 2)
    assert_true(host.commit(approval) is Err(@expansion.InvalidPhase))
    assert_true(host.reconcile() is Err(@expansion.InvalidPhase))
    assert_eq(store.writes, 2)
    backend.shutdown()
  })
}
