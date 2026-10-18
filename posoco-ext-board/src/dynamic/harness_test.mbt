///|
struct DynamicModel {
  mut payload : String
  mut fail : Bool
  mut delay : Int32
  mut calls : Int32
  mut active : Int32
  mut peak : Int32
}

///|
impl @posoco.Extension for DynamicModel with fn extension_id(_) {
  "dynamic-model"
}

///|
impl @posoco.Extension for DynamicModel with fn manifest(self) {
  @posoco.ExtensionManifest(id="dynamic-model", models=[self])
}

///|
impl @posoco.ModelPort for DynamicModel with fn provider_config(_) {
  @posoco.ProviderConfig::empty()
}

///|
impl @posoco.ModelPort for DynamicModel with fn chat(
  self,
  _scope,
  messages,
  _tools,
  _options,
  _stream,
) {
  self.calls += 1
  self.active += 1
  self.peak = self.peak.max(self.active)
  defer {
    self.active -= 1
  }
  if self.delay > 0 {
    @async.sleep(self.delay)
  }
  if self.fail {
    raise @posoco.ModelError::Transport("controlled test failure")
  }
  {
    completion: @kernel.Completion(
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
impl @posoco.ModelPort for DynamicModel with fn compact(_, _, _, _, _, _) {
  raise @posoco.ModelError::Transport("unexpected compact")
}

///|
struct DynamicResolver {
  mut denied : Bool
}

///|
impl @orchestration.BoardExecutionInputResolver for DynamicResolver with fn availability(
  self,
  _,
) {
  if self.denied {
    @orchestration.Denied
  } else {
    @orchestration.Available
  }
}

///|
impl @orchestration.BoardExecutionInputResolver for DynamicResolver with fn resolve(
  self,
  candidate,
) {
  if self.denied {
    return @orchestration.NotAuthorized
  }
  @orchestration.Authorized({
    execution_id: "exec-" + candidate.attempt_id,
    session_id: "session-" + candidate.attempt_id,
    input: "trusted-host-input",
    timeout_ms: Some(1000),
  })
}

///|
struct GraphDecision {
  grant : Bool
}

///|
impl @expansion.ExpansionApprover for GraphDecision with fn approve(self, _) {
  if self.grant {
    @expansion.Grant
  } else {
    @expansion.Deny
  }
}

///|
struct ScopeDecision {
  grant : Bool
}

///|
fn GraphDecision::GraphDecision(grant~ : Bool) -> GraphDecision {
  { grant, }
}

///|
fn ScopeDecision::ScopeDecision(grant~ : Bool) -> ScopeDecision {
  { grant, }
}

///|
impl @dynamic.ScopeExtensionApprover for ScopeDecision with fn approve(self, _) {
  if self.grant {
    @expansion.Grant
  } else {
    @expansion.Deny
  }
}

///|
struct DynamicHarness {
  board : @backend.BoardBackend
  owner : @execution.BoardExecutionOwner
  journal : @execution.MemoryBoardExecutionStore
  controller : @dynamic.DynamicWorkflowController
  model : DynamicModel
  channel : @execution.BoardExecutionResultChannel
  clock : Ref[Int64]
  resolver : DynamicResolver
}

///|
async fn dynamic_harness(
  group : @async.TaskGroup[Unit],
  enabled~ : Bool = true,
  max_executions~ : Int32 = 8,
  max_expansions~ : Int32 = 4,
  concurrency~ : Int32 = 2,
  scope_policy~ : @dynamic.DynamicScopeApprovalPolicy = HostApprover,
  board_store~ : &@store.BoardStore = @store.MemoryBoardStore(),
  execution_store~ : &@execution.BoardExecutionStore? = None,
) -> DynamicHarness {
  let clock = Ref(100L)
  let board = @backend.BoardBackend(store=board_store, now_ms=() => clock.val)
  board.attach(group)
  ignore(
    board
    .submit(
      @domain.CreateTask(
        id=@domain.BoardTaskId("parent"),
        title="Parent",
        description="",
        priority=@domain.Normal,
        definition_of_done=[],
        dependencies=[],
        at_ms=100L,
        expected_revision=0L,
      ),
    )
    .unwrap(),
  )
  let model = {
    payload: "execution-result",
    fail: false,
    delay: 1,
    calls: 0,
    active: 0,
    peak: 0,
  }
  let channel = @execution.BoardExecutionResultChannel(max_chars=65536)
  let journal = @execution.MemoryBoardExecutionStore()
  let store : &@execution.BoardExecutionStore = match execution_store {
    Some(s) => s
    None => journal
  }
  let owner = @execution.BoardExecutionOwner::with_slots(
    backend=board,
    store~,
    max_concurrency=concurrency,
    adapter_factory=index => {
      if index == 0 {
        @execution.PosocoBoardExecutionAdapter(
          extensions=() => [model],
          result_channel=channel,
        )
      } else {
        @execution.PosocoBoardExecutionAdapter(extensions=() => [model])
      }
    },
  ).unwrap()
  ignore(owner.attach(group).unwrap())
  let resolver = { denied: false, }
  let spec = @dynamic.DynamicWorkflowSpec(
    workflow_id="workflow",
    initial_scope=["parent"],
    max_executions~,
    max_elapsed_ms=60000,
    execution_timeout_ms=1000,
    max_concurrency=concurrency,
    expansion=if enabled {
      Some(
        @dynamic.DynamicExpansionSpec(
          max_expansions~,
          max_generated_tasks=20,
          max_depth=16,
          scope_approval=scope_policy,
        ),
      )
    } else {
      None
    },
  )
  let controller = @dynamic.DynamicWorkflowController::create(
    owner~,
    backend=board,
    resolver~,
    group~,
    spec~,
    now_ms=() => clock.val,
  ).unwrap()
  ignore(controller.start().unwrap())
  { board, owner, journal, controller, model, channel, clock, resolver, }
}

///|
async fn dynamic_close(h : DynamicHarness) -> Unit {
  assert_true(h.controller.shutdown())
  h.board.shutdown()
}

///|
async fn dynamic_move(
  h : DynamicHarness,
  id : String,
  to : @domain.BoardStage,
) -> Unit {
  let revision = h.board.state().unwrap().revision
  ignore(
    h.board
    .submit(
      @domain.MoveTask(
        id=@domain.BoardTaskId(id),
        to~,
        at_ms=h.clock.val,
        expected_revision=revision,
      ),
    )
    .unwrap(),
  )
}

///|
async fn dynamic_queue(h : DynamicHarness, task : String, id : String) -> Unit {
  let revision = h.board.state().unwrap().revision
  ignore(
    h.board
    .submit(
      @domain.QueueAttempt(
        id=@domain.AttemptId(id),
        task=@domain.BoardTaskId(task),
        kind=@domain.Execute,
        at_ms=h.clock.val,
        expected_revision=revision,
      ),
    )
    .unwrap(),
  )
}

///|
fn dynamic_payload(
  revision : Int64,
  id~ : String = "proposal",
  chain~ : Bool = false,
) -> String {
  let tasks : Array[Json] = [
    {
      "key": "a",
      "title": "Generated A",
      "description": "untrusted task content",
      "priority": "normal",
      "definition_of_done": ["host evidence"],
      "depends_on": [],
    },
  ]
  if chain {
    tasks.push({
      "key": "b",
      "title": "Generated B",
      "description": "",
      "priority": "normal",
      "definition_of_done": [],
      "depends_on": [{ "local": "a" }],
    })
  }
  let json : Json = {
    "schema_version": 1,
    "proposal_id": id,
    "parent_task_id": "parent",
    "base_revision": revision.to_double(),
    "tasks": tasks,
  }
  json.stringify()
}

///|
async fn dynamic_commit(
  h : DynamicHarness,
  id~ : String = "proposal",
  chain~ : Bool = false,
) -> Array[String] {
  let revision = h.board.state().unwrap().revision
  let prepared = h.controller.prepare_proposal(
    payload=dynamic_payload(revision, id~, chain~),
    authorization_id="authority-" + id,
    workflow_parent="parent",
    deadline_ms=50000L,
  )
  guard prepared is Ok(_) else { fail("prepare failed: \{Repr(prepared)}") }
  let preview = h.controller.preview().unwrap()
  let approval = h.controller
    .approve(preview~, approver=GraphDecision(grant=true))
    .unwrap()
  ignore(h.controller.commit(approval~).unwrap())
  let record = h.board
    .expansion_history()
    .unwrap()
    .filter(r => r.expansion_id.value == id)[0]
  record.mapping.map(p => p.task_id.value)
}

///|
async fn dynamic_authorize(
  h : DynamicHarness,
  ids : Array[String],
  id~ : String = "proposal",
  grant~ : Bool = true,
) -> Result[Unit, @dynamic.DynamicWorkflowError] {
  h.controller.authorize_scope_extension(
    workflow_id="workflow",
    expansion_id=id,
    approved_task_ids=ids,
    expected_revision=h.board.state().unwrap().revision,
    approver=ScopeDecision(grant~),
  )
}
