///|
struct PlanModel {
  mut payload : String
  fail : Bool
  mut calls : Int32
  mut stopped : Bool
}

///|
impl @posoco.Extension for PlanModel with fn extension_id(_self) {
  "plan-model"
}

///|
impl @posoco.Extension for PlanModel with fn manifest(self) {
  @posoco.ExtensionManifest::ExtensionManifest(id="plan-model", models=[self], lifecycle=[
    self,
  ])
}

///|
impl @posoco.Lifecycle for PlanModel with fn on_shutdown(self) {
  self.stopped = true
}

///|
impl @posoco.ModelPort for PlanModel with fn provider_config(_self) {
  @posoco.ProviderConfig::empty()
}

///|
impl @posoco.ModelPort for PlanModel with fn chat(
  self,
  _scope,
  messages,
  _tools,
  _options,
  _stream,
) {
  self.calls += 1
  if self.fail {
    raise @posoco.ModelError::Transport("controlled failure")
  }
  {
    completion: @kernel.Completion::Completion(
      content=[@kernel.Text(self.payload)],
      tool_calls=[],
      reasoning=None,
      finish_reason=Stop,
      usage=None,
    ),
    processed_messages: messages.to_owned(),
  }
}

///|
impl @posoco.ModelPort for PlanModel with fn compact(
  _self,
  _scope,
  _messages,
  _tools,
  _options,
  _trigger,
) {
  raise @posoco.ModelError::Transport("unexpected compact")
}

///|
fn plan_context() -> @expansion.DynamicPlanContext {
  {
    workflow_parent: "parent",
    workflow: Some("workflow"),
    authorization_id: "planning-auth",
    permitted_existing_dependencies: [],
    max_new_tasks: 20,
    max_new_edges: 60,
    max_payload_bytes: 65536,
    deadline_ms: 10000L,
  }
}

///|
/// Exact context the host derives from `planning_authority()` under the given
/// payload budget; the source refuses any other context.
fn host_plan_context(
  payload_bytes~ : Int32 = 65536,
) -> @expansion.DynamicPlanContext {
  {
    workflow_parent: "parent",
    workflow: Some("workflow"),
    authorization_id: "planning-auth",
    permitted_existing_dependencies: ["parent"],
    max_new_tasks: 20,
    max_new_edges: 60,
    max_payload_bytes: payload_bytes,
    deadline_ms: 10000L,
  }
}

///|
/// Trusted-host authority whose host-derived context is `host_plan_context()`.
fn planning_authority() -> @expansion.ExpansionAuthorization {
  @expansion.ExpansionAuthorization(
    authorization_id="planning-auth",
    workflow="workflow",
    workflow_parent="parent",
    workflow_task_scope=["parent"],
    permitted_existing_dependencies=["parent"],
    deadline_ms=10000L,
  )
}

///|
/// A valid two-task proposal: one permitted existing dependency on the parent
/// and one local chain. `base_revision` 4 is the post-settlement revision
/// after exactly one planning Attempt ran (create, queue, start, finish).
fn proposal_payload(
  proposal~ : String = "agent-plan",
  revision~ : Int32 = 4,
) -> String {
  let json : Json = {
    "schema_version": 1,
    "proposal_id": proposal,
    "parent_task_id": "parent",
    "base_revision": revision,
    "tasks": [
      {
        "key": "draft",
        "title": "Draft update",
        "description": "Draft the section",
        "priority": "high",
        "definition_of_done": ["Drafted"],
        "depends_on": [{ "existing": "parent" }],
      },
      {
        "key": "review",
        "title": "Review update",
        "description": "Review the draft",
        "priority": "normal",
        "definition_of_done": ["Reviewed"],
        "depends_on": [{ "local": "draft" }],
      },
    ],
  }
  json.stringify()
}

///|
struct GrantApprover {
  grant : Bool
}

///|
impl @expansion.ExpansionApprover for GrantApprover with fn approve(
  self,
  _preview,
) {
  if self.grant {
    @expansion.Grant
  } else {
    @expansion.Deny
  }
}

///|
async fn plan_board(group : @async.TaskGroup[Unit]) -> @backend.BoardBackend {
  let backend = @backend.BoardBackend(now_ms=() => 100L)
  backend.attach(group)
  assert_true(backend.bootstrap_snapshot() is Ok(_))
  assert_true(
    backend.handle_command({
      command_id: "parent",
      name: "board.task.create",
      expected_revision: 0L,
      args: {
        "id": "parent",
        "title": "Authorized parent",
        "description": "",
        "priority": "normal",
        "definition_of_done": [],
        "dependencies": [],
      },
    }).accepted,
  )
  assert_true(
    backend.handle_command({
      command_id: "planning-attempt",
      name: "board.attempt.queue",
      expected_revision: 1L,
      args: { "id": "planning-attempt", "task_id": "parent", "kind": "execute" },
    }).accepted,
  )
  backend
}

///|
/// Queue one more Execute Attempt on the authorized parent at the live
/// revision; every actual planning turn consumes exactly one queued Attempt.
async fn queue_execute_attempt(
  backend : @backend.BoardBackend,
  id~ : String,
) -> Unit {
  assert_true(
    backend.handle_command({
      command_id: "queue:" + id,
      name: "board.attempt.queue",
      expected_revision: backend.state().unwrap().revision,
      args: { "id": id, "task_id": "parent", "kind": "execute" },
    }).accepted,
  )
}

///|
fn plan_request(
  attempt~ : String = "planning-attempt",
  execution~ : String = "planning-execution",
  session~ : String = "planning-session",
  input~ : String = "Produce a bounded JSON proposal only. No tools are supplied. Expected post-settlement revision is 4; concurrent edits must invalidate it.",
) -> @execution.BoardExecutionRequest {
  {
    task_id: "parent",
    attempt_id: attempt,
    execution_id: execution,
    session_id: session,
    input,
    timeout_ms: Some(1000),
  }
}

///|
async test "actual owned Posoco Agent yields scoped proposal without output in identity journal" {
  @async.with_task_group(group => {
    let backend = plan_board(group)
    let model : PlanModel = {
      payload: "{\"schema_version\":1,\"proposal_id\":\"p\",\"parent_task_id\":\"parent\",\"base_revision\":4,\"tasks\":[]}",
      fail: false,
      calls: 0,
      stopped: false,
    }
    let channel = @execution.BoardExecutionResultChannel(max_chars=65536)
    let driver = @execution.PosocoBoardExecutionAdapter(
      extensions=() => [model],
      result_channel=channel,
    )
    let journal = @execution.MemoryBoardExecutionStore()
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter=driver,
      store=journal,
    )
    assert_true(owner.attach(group) is Ok(_))
    let source = @agent.OwnedAgentPlanSource(
      owner~,
      channel~,
      request=plan_request(),
      context=plan_context(),
      now_ms=() => 100L,
      authorize=_ => true,
    )
    let reply = source.generate(plan_context()).unwrap()
    assert_eq(reply.payload, model.payload)
    assert_eq(model.calls, 1)
    assert_true(model.stopped)
    let binding = journal.load().unwrap()[0]
    assert_eq(binding.phase, @execution.Settled)
    assert_eq(binding.outcome, Some(@execution.Completed))
    let encoded = @execution.encode_execution_journal([binding]).unwrap()
    assert_false(encoded.contains("schema_version\\\""))
    assert_false(encoded.contains(model.payload))
    assert_false(encoded.contains("Produce a bounded"))
    assert_eq(backend.state().unwrap().tasks.length(), 1)
    assert_eq(backend.state().unwrap().revision, 4L)
    assert_true(source.generate(plan_context()) is Err(@expansion.Denied))
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}

///|
async test "planning authorization default denial context mismatch and Agent failure never expand graph" {
  @async.with_task_group(group => {
    let backend = plan_board(group)
    let model : PlanModel = {
      payload: "not JSON",
      fail: true,
      calls: 0,
      stopped: false,
    }
    let channel = @execution.BoardExecutionResultChannel(max_chars=65536)
    let driver = @execution.PosocoBoardExecutionAdapter(
      extensions=() => [model],
      result_channel=channel,
    )
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter=driver,
      store=@execution.MemoryBoardExecutionStore(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let denied = @agent.OwnedAgentPlanSource(
      owner~,
      channel~,
      request=plan_request(),
      context=plan_context(),
      now_ms=() => 100L,
    )
    assert_true(denied.generate(plan_context()) is Err(@expansion.Denied))
    assert_eq(model.calls, 0)
    let source = @agent.OwnedAgentPlanSource(
      owner~,
      channel~,
      request=plan_request(),
      context=plan_context(),
      now_ms=() => 100L,
      authorize=_ => true,
    )
    assert_true(
      source.generate({ ..plan_context(), workflow: Some("wrong"), })
      is Err(@expansion.Denied),
    )
    assert_eq(model.calls, 0)
    assert_true(source.generate(plan_context()) is Err(@expansion.Unavailable))
    assert_eq(model.calls, 1)
    assert_true(model.stopped)
    assert_eq(backend.state().unwrap().tasks.length(), 1)
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}

///|
async test "actual Agent plans valid multi-task proposal through approval into one atomic commit and S4B outlook" {
  @async.with_task_group(group => {
    let backend = plan_board(group)
    let model : PlanModel = {
      payload: proposal_payload(),
      fail: false,
      calls: 0,
      stopped: false,
    }
    let channel = @execution.BoardExecutionResultChannel(max_chars=65536)
    let driver = @execution.PosocoBoardExecutionAdapter(
      extensions=() => [model],
      result_channel=channel,
    )
    let journal = @execution.MemoryBoardExecutionStore()
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter=driver,
      store=journal,
    )
    assert_true(owner.attach(group) is Ok(_))
    let source = @agent.OwnedAgentPlanSource(
      owner~,
      channel~,
      request=plan_request(),
      context=host_plan_context(),
      now_ms=() => 100L,
      authorize=_ => true,
    )
    let host = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
    // Generation runs only the planning Attempt lifecycle; the graph is
    // untouched and no expansion record exists yet.
    assert_true(
      host.generate(source, authorization=Some(planning_authority())) is Ok(_),
    )
    assert_eq(host.phase(), @expansion.Validated)
    assert_eq(model.calls, 1)
    let planned = backend.state().unwrap()
    assert_eq(planned.revision, 4L) // parent create + queue + start + finish
    assert_eq(planned.tasks.length(), 1)
    assert_eq(planned.attempts.length(), 1)
    assert_true(planned.attempts[0].status is @domain.Succeeded)
    assert_eq(planned.expansions.length(), 0)
    let records = journal.load().unwrap()
    assert_eq(records.length(), 1)
    assert_eq(records[0].phase, @execution.Settled)
    assert_eq(records[0].outcome, Some(@execution.Completed))
    // Preview binds exact content; approval is an explicit host decision and
    // still allocates nothing.
    let preview = host.preview().unwrap()
    assert_eq(preview.proposal_id, "agent-plan")
    assert_eq(preview.proposal().tasks.length(), 2)
    assert_eq(preview.workflow_task_scope(), ["parent"])
    assert_true(preview.digest.has_prefix("sha256:"))
    let approval = host
      .approve(preview, GrantApprover::{ grant: true, })
      .unwrap()
    assert_eq(backend.state().unwrap(), planned)
    // One whole-proposal commit applies both tasks atomically.
    assert_true(host.commit(approval) is Ok(_))
    assert_eq(host.phase(), @expansion.Committed)
    let committed = backend.state().unwrap()
    assert_eq(committed.revision, 5L)
    assert_eq(committed.tasks.length(), 3)
    assert_eq(committed.attempts.length(), 1)
    assert_eq(committed.expansions.length(), 1)
    let record = committed.expansions[0]
    assert_eq(record.expansion_id.value, "agent-plan")
    assert_eq(record.workflow_id, "workflow")
    assert_eq(record.parent_task_id, @domain.BoardTaskId("parent"))
    assert_eq(record.mapping.map(pair => pair.local_ref), ["draft", "review"])
    assert_true(record.mapping[0].task_id.value.has_prefix("expanded-"))
    assert_true(record.mapping[1].task_id.value.has_prefix("expanded-"))
    assert_false(record.mapping[0].task_id == record.mapping[1].task_id)
    assert_true(record.content_digest.has_prefix("sha256:"))
    let draft = committed.tasks.filter(task => {
      task.id == record.mapping[0].task_id
    })
    let review = committed.tasks.filter(task => {
      task.id == record.mapping[1].task_id
    })
    assert_eq(draft.length(), 1)
    assert_eq(review.length(), 1)
    let draft = draft[0]
    let review = review[0]
    assert_eq(draft.title, "Draft update")
    assert_true(draft.stage is @domain.Created)
    assert_eq(draft.dependencies, [@domain.BoardTaskId("parent")])
    assert_eq(draft.definition_of_done, ["Drafted"])
    assert_eq(review.title, "Review update")
    assert_true(review.stage is @domain.Created)
    assert_eq(review.dependencies, [record.mapping[0].task_id])
    assert_eq(
      host.mapping(),
      record.mapping.map(pair => (pair.local_ref, pair.task_id)),
    )
    // The existing S4B planner classifies every committed task: Created with
    // no attempts, blocked until a host readies it, never executed here.
    let outlook = host.outlook().unwrap()
    assert_eq(outlook.map(row => row.key), ["draft", "review"])
    assert_eq(
      outlook.map(row => row.task_id),
      record.mapping.map(pair => pair.task_id.value),
    )
    assert_true(
      outlook.all(row => {
        row.stage_created &&
        row.queued_execute_attempts == 0 &&
        !row.unexpected_state &&
        row.outside_workflow_task_scope &&
        row.class is @expansion.Blocked(_)
      }),
    )
    // Single use: the consumed source can never drive a second planning turn.
    assert_true(source.generate(host_plan_context()) is Err(@expansion.Denied))
    assert_eq(model.calls, 1)
    // The identity journal never carries input or model output.
    let encoded = @execution.encode_execution_journal(journal.load().unwrap()).unwrap()
    assert_false(encoded.contains("agent-plan"))
    assert_false(encoded.contains("Draft update"))
    assert_false(encoded.contains("Produce a bounded"))
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}

///|
async test "invalid or unauthorized Agent proposals are rejected before approval and mutate no graph" {
  @async.with_task_group(group => {
    let backend = plan_board(group)
    queue_execute_attempt(backend, id="attempt-version")
    queue_execute_attempt(backend, id="attempt-parent")
    queue_execute_attempt(backend, id="attempt-bytes")
    let model : PlanModel = {
      payload: "not JSON",
      fail: false,
      calls: 0,
      stopped: false,
    }
    let channel = @execution.BoardExecutionResultChannel(max_chars=65536)
    let driver = @execution.PosocoBoardExecutionAdapter(
      extensions=() => [model],
      result_channel=channel,
    )
    let journal = @execution.MemoryBoardExecutionStore()
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter=driver,
      store=journal,
    )
    assert_true(owner.attach(group) is Ok(_))
    // 1. Malformed model JSON dies in the strict decoder.
    {
      let source = @agent.OwnedAgentPlanSource(
        owner~,
        channel~,
        request=plan_request(),
        context=host_plan_context(),
        now_ms=() => 100L,
        authorize=_ => true,
      )
      let host = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
      assert_true(
        host.generate(source, authorization=Some(planning_authority()))
        is Err(
          @expansion.DecodeFailed(@expansion.MalformedJson(offset=_, reason=_))
        ),
      )
      assert_eq(host.phase(), @expansion.Rejected)
      assert_true(host.preview() is Err(@expansion.InvalidPhase))
      assert_eq(model.calls, 1)
    }
    // 2. A future schema version is never silently accepted.
    {
      model.payload = proposal_payload().replace(
        old="\"schema_version\":1",
        new="\"schema_version\":2",
      )
      let source = @agent.OwnedAgentPlanSource(
        owner~,
        channel~,
        request=plan_request(
          attempt="attempt-version",
          execution="planning-version",
          session="session-version",
        ),
        context=host_plan_context(),
        now_ms=() => 100L,
        authorize=_ => true,
      )
      let host = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
      assert_true(
        host.generate(source, authorization=Some(planning_authority()))
        is Err(@expansion.DecodeFailed(@expansion.InvalidVersion(found="2"))),
      )
      assert_eq(host.phase(), @expansion.Rejected)
      assert_true(host.preview() is Err(@expansion.InvalidPhase))
      assert_eq(model.calls, 2)
    }
    // 3. A decoded proposal for another parent is unauthorized.
    {
      model.payload = proposal_payload().replace(
        old="\"parent_task_id\":\"parent\"",
        new="\"parent_task_id\":\"elsewhere\"",
      )
      let source = @agent.OwnedAgentPlanSource(
        owner~,
        channel~,
        request=plan_request(
          attempt="attempt-parent",
          execution="planning-parent",
          session="session-parent",
        ),
        context=host_plan_context(),
        now_ms=() => 100L,
        authorize=_ => true,
      )
      let host = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
      assert_true(
        host.generate(source, authorization=Some(planning_authority()))
        is Err(@expansion.InvalidAuthorization("parent mismatch")),
      )
      assert_eq(host.phase(), @expansion.Rejected)
      assert_true(host.preview() is Err(@expansion.InvalidPhase))
      assert_eq(model.calls, 3)
    }
    // 4. Output exceeding the byte budget is dropped at the source, before
    // the host ever decodes it.
    {
      model.payload = proposal_payload().replace(
        old="Draft the section",
        new="Draft the 🚀 section 🚀 🚀",
      )
      let source = @agent.OwnedAgentPlanSource(
        owner~,
        channel~,
        request=plan_request(
          attempt="attempt-bytes",
          execution="planning-bytes",
          session="session-bytes",
          input="Plan two tasks.",
        ),
        context=host_plan_context(payload_bytes=64),
        now_ms=() => 100L,
        authorize=_ => true,
      )
      let host = @expansion.ExpansionHost(
        backend~,
        policy=@expansion.ExpansionPolicy(max_payload_bytes=64),
        now_ms=() => 100L,
      )
      assert_true(
        host.generate(source, authorization=Some(planning_authority()))
        is Err(@expansion.SourceFailed(@expansion.Unavailable)),
      )
      assert_eq(host.phase(), @expansion.Rejected)
      assert_true(host.preview() is Err(@expansion.InvalidPhase))
      assert_eq(model.calls, 4)
    }
    // Only planning Attempt lifecycle mutations happened (queue, start,
    // finish per turn). No approval was possible, no task and no expansion
    // record was ever created.
    let snapshot = backend.state().unwrap()
    assert_eq(snapshot.tasks.length(), 1)
    assert_eq(snapshot.expansions.length(), 0)
    assert_eq(snapshot.revision, 13L)
    assert_eq(snapshot.attempts.length(), 4)
    assert_true(
      snapshot.attempts.all(attempt => attempt.status is @domain.Succeeded),
    )
    let records = journal.load().unwrap()
    assert_eq(records.length(), 4)
    assert_true(
      records.all(record => {
        record.phase is @execution.Settled &&
        record.outcome is Some(@execution.Completed)
      }),
    )
    assert_true(model.stopped)
    let encoded = @execution.encode_execution_journal(records).unwrap()
    assert_false(encoded.contains("agent-plan"))
    assert_false(encoded.contains("Draft the"))
    assert_false(encoded.contains("Plan two tasks."))
    assert_false(encoded.contains("Produce a bounded"))
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}

///|
async test "unread output of another execution blocks planning and is dropped without leaking" {
  @async.with_task_group(group => {
    let backend = plan_board(group)
    queue_execute_attempt(backend, id="foreign-attempt")
    let model : PlanModel = {
      payload: proposal_payload(),
      fail: false,
      calls: 0,
      stopped: false,
    }
    let channel = @execution.BoardExecutionResultChannel(max_chars=65536)
    let driver = @execution.PosocoBoardExecutionAdapter(
      extensions=() => [model],
      result_channel=channel,
    )
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter=driver,
      store=@execution.MemoryBoardExecutionStore(),
    )
    assert_true(owner.attach(group) is Ok(_))
    // A direct, non-planning execution captures its output first.
    let foreign = owner
      .execute(
        plan_request(
          attempt="foreign-attempt",
          execution="foreign-execution",
          session="foreign-session",
          input="Side quest",
        ),
      )
      .unwrap()
      .wait()
    assert_eq(foreign.phase, @execution.Settled)
    assert_eq(foreign.outcome, Some(@execution.Completed))
    assert_eq(model.calls, 1)
    // A wrongly scoped binding can neither read nor consume the output.
    assert_eq(channel.take({ ..foreign, execution_id: "other", }), None)
    assert_eq(channel.take({ ..foreign, session_id: "other", }), None)
    assert_eq(channel.take({ ..foreign, phase: @execution.Finished, }), None)
    // The occupied channel refuses planning admission before any model call.
    let source = @agent.OwnedAgentPlanSource(
      owner~,
      channel~,
      request=plan_request(),
      context=host_plan_context(),
      now_ms=() => 100L,
      authorize=_ => true,
    )
    let host = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
    assert_true(
      host.generate(source, authorization=Some(planning_authority()))
      is Err(@expansion.SourceFailed(@expansion.Unavailable)),
    )
    assert_eq(model.calls, 1)
    assert_eq(host.phase(), @expansion.Rejected)
    assert_true(host.preview() is Err(@expansion.InvalidPhase))
    // The planning request was never admitted, so the journal holds only the
    // foreign execution and the planning Attempt is still untouched Queued.
    assert_eq(owner.bindings().length(), 1)
    let snapshot = backend.state().unwrap()
    assert_eq(snapshot.tasks.length(), 1)
    assert_eq(snapshot.expansions.length(), 0)
    assert_eq(snapshot.attempts.length(), 2)
    assert_eq(
      snapshot.attempts
      .filter(attempt => attempt.status is @domain.Succeeded)
      .length(),
      1,
    )
    assert_eq(
      snapshot.attempts
      .filter(attempt => attempt.status is @domain.Queued)
      .length(),
      1,
    )
    // The source dropped the ephemeral foreign output on exit: it can never
    // satisfy a later planning read and leaks to no other consumer.
    assert_true(driver.ready())
    assert_eq(channel.take(foreign), None)
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}
