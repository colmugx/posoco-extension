///|
struct ExpansionFaultStore {
  inner : @store.MemoryBoardStore
  mut fail_revision : Int64?
  mut visible : Bool
  mut ambiguous : Bool
  mut delay : Int32
  mut entered : Bool
  mut calls : Int32
}

///|
fn expansion_fault_store() -> ExpansionFaultStore {
  {
    inner: @store.MemoryBoardStore(),
    fail_revision: None,
    visible: false,
    ambiguous: false,
    delay: 0,
    entered: false,
    calls: 0,
  }
}

///|
impl @store.BoardStore for ExpansionFaultStore with fn load(self) {
  self.inner.load()
}

///|
impl @store.BoardStore for ExpansionFaultStore with fn persist(
  self,
  snapshot,
  events,
) {
  self.calls += 1
  if self.fail_revision == Some(snapshot.revision) {
    self.entered = true
    if self.visible {
      ignore(self.inner.persist(snapshot, events).unwrap())
    }
    if self.delay > 0 {
      @async.sleep(self.delay)
    }
    if self.ambiguous {
      return Err(
        @store.DurabilityUncertain(
          "controlled lost persistence acknowledgement",
        ),
      )
    }
    return Err(@store.Io("controlled pre-visibility failure"))
  }
  self.inner.persist(snapshot, events)
}

///|
async fn durability_approval(
  h : DynamicHarness,
) -> @expansion.ExpansionApproval {
  ignore(
    h.controller
    .prepare_proposal(
      payload=dynamic_payload(h.board.state().unwrap().revision),
      authorization_id="fault-authority",
      workflow_parent="parent",
      deadline_ms=50000L,
    )
    .unwrap(),
  )
  let preview = h.controller.preview().unwrap()
  h.controller.approve(preview~, approver=GraphDecision(grant=true)).unwrap()
}

///|
async test "lost graph commit acknowledgement reconciles one exact durable identity without replay" {
  @async.with_task_group(group => {
    let store = expansion_fault_store()
    let h = dynamic_harness(group, board_store=store)
    let approval = durability_approval(h)
    store.fail_revision = Some(h.board.state().unwrap().revision + 1L)
    store.visible = true
    store.ambiguous = true
    assert_true(
      h.controller.commit(approval~)
      is Err(@dynamic.ExpansionFailed(@expansion.Backend(_))),
    )
    assert_eq(h.controller.status().expansion_phase, Some(@expansion.Uncertain))
    let committed = h.board.state().unwrap()
    assert_eq(committed.tasks.length(), 2)
    assert_eq(committed.expansions.length(), 1)
    assert_eq(h.controller.status().scope, ["parent"])
    let calls = store.calls
    h.controller.discard_proposal()
    h.controller.cancel()
    assert_eq(h.controller.status().expansion_phase, Some(@expansion.Uncertain))
    assert_eq(h.controller.reconcile(), Ok(true))
    assert_eq(store.calls, calls)
    assert_eq(h.board.state().unwrap(), committed)
    assert_true(h.controller.commit(approval~) is Err(_))
    assert_eq(store.calls, calls)
    assert_eq(
      h.board
      .event_history()
      .filter(e => e.kind == "board.graph.expanded")
      .length(),
      1,
    )
    dynamic_close(h)
  })
}

///|
async test "absent uncertain graph evidence stays frozen and definitive failure publishes nothing" {
  @async.with_task_group(group => {
    for ambiguous in [false, true] {
      let store = expansion_fault_store()
      let h = dynamic_harness(group, board_store=store)
      let approval = durability_approval(h)
      let before = h.board.state().unwrap()
      store.fail_revision = Some(before.revision + 1L)
      store.ambiguous = ambiguous
      assert_true(h.controller.commit(approval~) is Err(_))
      assert_eq(h.board.state().unwrap(), before)
      assert_eq(h.board.event_history().length(), 1)
      let calls = store.calls
      if ambiguous {
        assert_eq(h.controller.reconcile(), Ok(false))
        assert_eq(
          h.controller.prepare_proposal(
            payload=dynamic_payload(before.revision, id="replacement"),
            authorization_id="replacement-auth",
            workflow_parent="parent",
            deadline_ms=50000L,
          ),
          Err(@dynamic.ProposalActive),
        )
      } else {
        assert_eq(
          h.controller.status().expansion_phase,
          Some(@expansion.Conflict),
        )
      }
      assert_eq(store.calls, calls)
      dynamic_close(h)
    }
  })
}

///|
async test "partial preparation is independently durable and never automatically retried" {
  @async.with_task_group(group => {
    let store = expansion_fault_store()
    let h = dynamic_harness(group, board_store=store)
    let ids = dynamic_commit(h)
    ignore(dynamic_authorize(h, ids).unwrap())
    let revision = h.board.state().unwrap().revision
    store.fail_revision = Some(revision + 2L)
    assert_true(
      h.controller.prepare_task(
        task_id=ids[0],
        attempt_id="partial",
        expected_revision=revision,
      )
      is Err(@dynamic.PreparationFailed(_)),
    )
    let state = h.board.state().unwrap()
    assert_eq(state.revision, revision + 1L)
    assert_eq(
      state.tasks.filter(t => t.id.value == ids[0])[0].stage,
      @domain.Refining,
    )
    assert_true(state.attempts.is_empty())
    assert_eq(h.controller.status().partial_preparations[0].completed_steps, 1)
    let calls = store.calls
    assert_eq(
      h.controller.prepare_task(
        task_id=ids[0],
        attempt_id="replacement",
        expected_revision=state.revision,
      ),
      Err(@dynamic.PreparationBlocked),
    )
    assert_eq(
      h.controller.reconcile_preparation(task_id=ids[0]).unwrap().completed_steps,
      1,
    )
    assert_eq(store.calls, calls)
    dynamic_close(h)
  })
}

///|
async test "uncertain final preparation freezes dispatch until exact Attempt is read back without command replay" {
  @async.with_task_group(group => {
    let store = expansion_fault_store()
    let h = dynamic_harness(group, board_store=store)
    let ids = dynamic_commit(h)
    ignore(dynamic_authorize(h, ids).unwrap())
    let revision = h.board.state().unwrap().revision
    store.fail_revision = Some(revision + 3L)
    store.visible = true
    store.ambiguous = true
    assert_true(
      h.controller.prepare_task(
        task_id=ids[0],
        attempt_id="uncertain-attempt",
        expected_revision=revision,
      )
      is Err(@dynamic.PreparationUncertain(_)),
    )
    assert_eq(
      h.board.state().unwrap().attempts[0].id.value,
      "uncertain-attempt",
    )
    assert_eq(h.controller.run_wave(), Err(@dynamic.PreparationBlocked))
    let calls = store.calls
    let record = h.controller.reconcile_preparation(task_id=ids[0]).unwrap()
    assert_false(record.uncertain)
    assert_eq(record.completed_steps, 3)
    assert_eq(store.calls, calls)
    store.fail_revision = None
    ignore(h.controller.run_wave().unwrap())
    assert_eq(h.controller.wait_boundary().unwrap().runner.settled, 1)
    assert_eq(h.owner.bindings().length(), 1)
    dynamic_close(h)
  })
}

///|
async test "cancelled commit waiter retains identity and shutdown drains the accepted graph transaction" {
  @async.with_task_group(group => {
    let store = expansion_fault_store()
    let h = dynamic_harness(group, board_store=store)
    let approval = durability_approval(h)
    store.fail_revision = Some(h.board.state().unwrap().revision + 1L)
    store.visible = true
    store.ambiguous = true
    store.delay = 60
    let commit = group.spawn(() => h.controller.commit(approval~))
    while !store.entered {
      @async.sleep(1)
    }
    assert_true(h.controller.pause())
    assert_true(commit.wait() is Err(_))
    assert_eq(h.controller.status().expansion_phase, Some(@expansion.Uncertain))
    let stopped = h.controller.shutdown()
    assert_true(stopped)
    let disk = store.inner.load().unwrap().snapshot
    assert_eq(disk.expansions.length(), 1)
    assert_eq(
      h.board
      .event_history()
      .filter(e => e.kind == "board.graph.expanded")
      .length(),
      1,
    )
    // The paused/cancelled controller never authorizes or executes the graph.
    assert_eq(h.controller.status().scope, ["parent"])
    assert_eq(h.model.calls, 0)
    h.board.shutdown()
  })
}
