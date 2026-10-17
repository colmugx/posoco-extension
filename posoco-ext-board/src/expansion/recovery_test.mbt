///|
/// Regression: a freshly attached backend settles its startup restore
/// asynchronously, and until then the coordinator answers queries with
/// `Initializing`. `recover_expansion` is the after-restart identity lookup,
/// so it must wait out that window instead of surfacing a transient error.
async test "recovery reads settled durable history right after attach" {
  @async.with_task_group(group => {
    let store : @store.MemoryBoardStore = @store.MemoryBoardStore::MemoryBoardStore()
    let first = @backend.BoardBackend(store~, now_ms=() => 100L)
    first.attach(group)
    assert_true(
      first.handle_command({
        command_id: "create-parent",
        name: "board.task.create",
        expected_revision: 0L,
        args: {
          "id": "parent",
          "title": "Parent",
          "description": "",
          "priority": "normal",
          "definition_of_done": [],
          "dependencies": [],
        },
      }).accepted,
    )
    let host = @expansion.ExpansionHost(backend=first, now_ms=() => 100L)
    assert_true(
      host.prepare(payload(), authorization=Some(authority())) is Ok(_),
    )
    let approval = host
      .approve(host.preview().unwrap(), HostApprover::{ grant: true, })
      .unwrap()
    assert_true(host.commit(approval) is Ok(_))
    first.shutdown()
    let recovered = @backend.BoardBackend(store~, now_ms=() => 200L)
    recovered.attach(group)
    let record = @expansion.recover_expansion(recovered, "proposal-1").unwrap()
    let record = record.unwrap()
    assert_eq(record.expansion_id, @domain.ExpansionId("proposal-1"))
    assert_eq(record.mapping.map(pair => pair.local_ref), ["a", "b"])
    assert_true(record.content_digest.has_prefix("sha256:"))
    // An unknown proposal is an absence, never an error or a replay permit.
    assert_true(
      @expansion.recover_expansion(recovered, "other").unwrap() is None,
    )
    recovered.shutdown()
    // A backend that was never attached cannot answer at all.
    let detached = @backend.BoardBackend(store~, now_ms=() => 200L)
    assert_true(
      @expansion.recover_expansion(detached, "proposal-1")
      is Err(@expansion.Backend(@coordinator.NotAttached)),
    )
  })
}
