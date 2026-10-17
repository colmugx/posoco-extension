///|
fn task_json(
  key : String,
  dependencies~ : Json = [],
  title~ : String = "New task",
  description~ : String = "Plan only",
  dod~ : Json = ["Reviewed"],
) -> Json {
  {
    "key": key,
    "title": title,
    "description": description,
    "priority": "normal",
    "definition_of_done": dod,
    "depends_on": dependencies,
  }
}

///|
fn payload(
  tasks~ : Array[Json] = [
    task_json("a"),
    task_json("b", dependencies=[{ "local": "a" }, { "existing": "parent" }]),
  ],
  proposal~ : String = "proposal-1",
  revision~ : Int32 = 1,
) -> String {
  let json : Json = {
    "schema_version": 1,
    "proposal_id": proposal,
    "parent_task_id": "parent",
    "base_revision": revision,
    "tasks": Json::array(tasks),
  }
  json.stringify()
}

///|
fn decode(
  text : String,
  policy~ : @expansion.ExpansionPolicy = @expansion.ExpansionPolicy(),
) -> Result[@expansion.DraftExpansion, @expansion.ExpansionDecodeError] {
  @expansion.decode_expansion_proposal(payload=text, policy~)
}

///|
test "strict schema identity, explicit references, numbers, Unicode and fields" {
  let good = payload()
  let draft = decode(good).unwrap()
  assert_eq(draft.proposal_id, "proposal-1")
  assert_eq(draft.parent_task_id, "parent")
  assert_eq(draft.base_revision, 1L)
  assert_eq(draft.tasks[1].depends_on, [
    @expansion.NewTask(key="a"),
    @expansion.ExistingTask(id=@domain.BoardTaskId("parent")),
  ])
  let invalid = [
    "",
    "null",
    "[]",
    good + "x",
    "```json\n" + good + "\n```",
    good.replace(old="\"schema_version\":1", new="\"schema_version\":\"1\""),
    good.replace(old="\"schema_version\":1", new="\"schema_version\":1.0"),
    good.replace(old="\"schema_version\":1", new="\"schema_version\":1e0"),
    good.replace(old="\"schema_version\":1", new="\"schema_version\":2"),
    good.replace(old="\"schema_version\":1", new="\"version\":1"),
    good.replace(old="\"base_revision\":1", new="\"base_revision\":-0"),
    good.replace(old="\"base_revision\":1", new="\"base_revision\":1e0"),
    good.replace(old="\"base_revision\":1", new="\"base_revision\":1.0"),
    good.replace(old="\"base_revision\":1", new="\"base_revision\":01"),
    good.replace(
      old="\"base_revision\":1",
      new="\"base_revision\":9007199254740992",
    ),
    good.replace(old="\"base_revision\":1", new="\"base_revision\":null"),
    good.replace(old="\"proposal_id\":\"proposal-1\",", new=""),
    good.replace(
      old="\"proposal_id\":\"proposal-1\"",
      new="\"proposal_id\":\" \"",
    ),
    good.replace(
      old="\"proposal_id\":\"proposal-1\"",
      new="\"proposal_id\":\"p\\u00a0x\"",
    ),
    good.replace(
      old="\"proposal_id\":\"proposal-1\"",
      new="\"proposal_id\":\"p\\u0000x\"",
    ),
    good.replace(
      old="\"proposal_id\":\"proposal-1\"",
      new="\"proposal_id\":\"p\\ud800\"",
    ),
    good.replace(
      old="\"proposal_id\":\"proposal-1\"",
      new="\"proposal_id\":\"p\\udc00\"",
    ),
    good.replace(
      old="\"proposal_id\":\"proposal-1\"",
      new="\"proposal_id\":\"p\\ud800\\u0041\"",
    ),
    good.replace(old="\"priority\":\"normal\"", new="\"priority\":\"urgent\""),
    good.replace(old="\"priority\":\"normal\"", new="\"priority\":1"),
    good.replace(old="\"title\":\"New task\"", new="\"title\":\"   \""),
    good.replace(old="\"title\":\"New task\"", new="\"title\":\" padded \""),
    good.replace(
      old="\"local\":\"a\"",
      new="\"local\":\"missing\",\"existing\":\"parent\"",
    ),
    good.replace(old="{\"local\":\"a\"}", new="\"a\""),
    good.replace(old="{\"local\":\"a\"}", new="{}"),
    good.replace(old="{\"local\":\"a\"}", new="{\"other\":\"a\"}"),
    good.replace(
      old="\"title\":\"New task\"",
      new="\"title\":\"one\",\"title\":\"two\"",
    ),
    good.replace(
      old="\"title\":\"New task\"",
      new="\"title\":\"one\",\"\\u0074itle\":\"two\"",
    ),
    good.replace(
      old="\"schema_version\":1",
      new="\"schema_version\":1,\"schema_version\":1",
    ),
    good.replace(
      old="\"schema_version\":1",
      new="\"schema_version\":1,\"stage\":\"ready\"",
    ),
    good.replace(
      old="\"title\":\"New task\"",
      new="\"title\":\"New task\",\"attempt\":\"x\"",
    ),
    good.replace(old="\"title\":\"New task\"", new="\"title\":\"bad\nraw\""),
    good.replace(old="\"title\":\"New task\"", new="\"title\":\"bad\\x00\""),
    good.replace(old="\"parent_task_id\":\"parent\",", new=""),
    good.replace(old="\"base_revision\":1,", new=""),
    good.replace(old="\"schema_version\":1", new="\"schema_version\":true"),
    good.replace(old="\"schema_version\":1", new="\"schema_version\":false"),
    good.replace(old="\"schema_version\":1", new="\"schema_version\":null"),
    good.replace(
      old="{\"local\":\"a\"}",
      new="{\"local\":\"a\",\"local\":\"b\"}",
    ),
    good.replace(old="{\"local\":\"a\"}", new="{\"local\":1}"),
    payload(tasks=[
      {
        "key": "a",
        "title": "New task",
        "priority": "normal",
        "definition_of_done": [],
        "depends_on": [],
      },
    ]),
    payload(tasks=[
      {
        "key": "a",
        "title": "New task",
        "description": "Plan only",
        "definition_of_done": [],
        "depends_on": [],
      },
    ]),
    payload(tasks=[
      {
        "title": "New task",
        "description": "Plan only",
        "priority": "normal",
        "definition_of_done": [],
        "depends_on": [],
      },
    ]),
    payload(tasks=[
      {
        "key": "a",
        "description": "Plan only",
        "priority": "normal",
        "definition_of_done": [],
        "depends_on": [],
      },
    ]),
    payload(tasks=[
      {
        "key": "a",
        "title": "New task",
        "description": "Plan only",
        "priority": "normal",
        "depends_on": [],
      },
    ]),
    payload(tasks=[]),
  ]
  for index, text in invalid {
    assert_true(decode(text) is Err(_), msg="invalid case \{index}: \{text}")
  }
  assert_true(
    decode(payload(tasks=[task_json("unicode", title="Valid 🚀 task")]))
    is Ok(_),
  )
  assert_true(
    decode(
      good.replace(
        old="\"title\":\"New task\"",
        new="\"title\":\"Valid \\ud83d\\ude80 task\"",
      ),
    )
    is Ok(_),
  )
}

///|
test "all structural bounds are explicit and cannot be widened" {
  let policy = @expansion.ExpansionPolicy(
    max_tasks=1000,
    max_edges=1000,
    max_title_chars=1000,
  )
  assert_eq(policy.max_tasks(), 20)
  assert_eq(policy.max_edges(), 60)
  assert_eq(policy.max_title_chars(), 256)
  assert_true(
    decode(payload(tasks=[task_json("a", title="x".repeat(256))])) is Ok(_),
  )
  assert_true(
    decode(payload(tasks=[task_json("a", title="x".repeat(257))])) is Err(_),
  )
  assert_true(
    decode(payload(tasks=Array::makei(21, i => task_json("k\{i}")))) is Err(_),
  )
  assert_true(decode(payload(tasks=[task_json("x".repeat(129))])) is Err(_))
  assert_true(decode("[".repeat(17) + "0" + "]".repeat(17)) is Err(_))
  assert_true(decode(" ".repeat(65537) + payload()) is Err(_))
  assert_true(
    decode(payload(), policy=@expansion.ExpansionPolicy(max_payload_bytes=64))
    is Err(_),
  )
  assert_true(
    decode(payload(), policy=@expansion.ExpansionPolicy(max_depth=2)) is Err(_),
  )
  let deps : Array[Json] = Array::makei(13, i => { "existing": "t\{i}" })
  assert_true(
    decode(payload(tasks=[task_json("a", dependencies=Json::array(deps))]))
    is Err(_),
  )
  let twelve : Array[Json] = Array::makei(12, i => { "existing": "t\{i}" })
  assert_true(
    decode(
      payload(
        tasks=Array::makei(6, i => {
          task_json("k\{i}", dependencies=Json::array(twelve))
        }),
      ),
    )
    is Err(_),
  )
  // Exact ceilings and text bounds the first rejection list does not cover.
  assert_true(decode(payload(tasks=[task_json("x".repeat(128))])) is Ok(_))
  assert_true(
    decode(payload(tasks=[task_json("a", dependencies=Json::array(twelve))]))
    is Ok(_),
  )
  assert_true(
    decode(payload(tasks=[task_json("a", dod=Json::array(["x".repeat(256)]))]))
    is Ok(_),
  )
  assert_true(
    decode(payload(tasks=[task_json("a", dod=Json::array(["x".repeat(257)]))]))
    is Err(_),
  )
  assert_true(
    decode(payload(tasks=[task_json("a", dod=Json::array(["", " "]))]))
    is Err(_),
  )
  assert_true(
    decode(payload(tasks=[task_json("a", description="x".repeat(4096))]))
    is Ok(_),
  )
  assert_true(
    decode(payload(tasks=[task_json("a", description="x".repeat(4097))]))
    is Err(_),
  )
  // An explicitly empty description is allowed; whitespace-only text is not.
  assert_true(decode(payload(tasks=[task_json("a", description="")])) is Ok(_))
  assert_true(
    decode(payload(tasks=[task_json("a", description="  ")]))
    is Err(@expansion.InvalidString(..)),
  )
}

///|
struct HostApprover {
  grant : Bool
}

///|
impl @expansion.ExpansionApprover for HostApprover with fn approve(
  self,
  preview,
) {
  // Attempted mutation of a detached copy must not alter the approved content.
  preview.proposal().tasks.clear()
  if self.grant {
    @expansion.Grant
  } else {
    @expansion.Deny
  }
}

///|
struct CountingAllocator {
  mut calls : Int32
}

///|
impl @expansion.ExpansionIdAllocator for CountingAllocator with fn canonical_task_id(
  self,
  proposal_id~,
  key~,
  index~,
) {
  self.calls += 1
  "\{proposal_id}-\{key}-\{index}"
}

///|
fn authority(
  workflow~ : String = "workflow",
  scope~ : Array[String] = ["parent"],
  deps~ : Array[String] = ["parent"],
  deadline~ : Int64 = 1000L,
  tasks~ : Int32 = 20,
  edges~ : Int32 = 60,
) -> @expansion.ExpansionAuthorization {
  @expansion.ExpansionAuthorization(
    authorization_id="auth",
    workflow~,
    workflow_parent="parent",
    workflow_task_scope=scope,
    permitted_existing_dependencies=deps,
    deadline_ms=deadline,
    max_tasks=tasks,
    max_edges=edges,
  )
}

///|
async fn create_parent(backend : @backend.BoardBackend) -> Unit {
  assert_true(
    backend.handle_command({
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
}

///|
async fn board(group : @async.TaskGroup[Unit]) -> @backend.BoardBackend {
  let backend = @backend.BoardBackend(now_ms=() => 100L)
  backend.attach(group)
  create_parent(backend)
  backend
}

///|
async test "four steps exact approval atomic multi-task and S4B outlook" {
  @async.with_task_group(group => {
    let backend = board(group)
    let allocator : CountingAllocator = { calls: 0, }
    let host = @expansion.ExpansionHost(backend~, allocator~, now_ms=() => 100L)
    let frozen_scope = ["parent"]
    let frozen_deps = ["parent"]
    let auth = authority(scope=frozen_scope, deps=frozen_deps)
    frozen_scope.clear()
    frozen_deps.clear()
    assert_true(host.prepare(payload(), authorization=Some(auth)) is Ok(_))
    assert_eq(host.phase(), @expansion.Validated)
    assert_eq(allocator.calls, 0)
    let preview = host.preview().unwrap()
    assert_eq(preview.revision, 1L)
    assert_true(preview.digest.has_prefix("sha256:"))
    assert_eq(preview.digest.length(), 71)
    assert_eq(preview.workflow_task_scope(), ["parent"])
    assert_eq(preview.permitted_existing_dependencies(), ["parent"])
    assert_eq(preview.proposal().tasks.length(), 2)
    preview.proposal().tasks[0].definition_of_done.clear()
    preview.permitted_existing_dependencies().clear()
    let approval = host
      .approve(preview, HostApprover::{ grant: true, })
      .unwrap()
    assert_eq(allocator.calls, 0)
    assert_eq(backend.state().unwrap().tasks.length(), 1)
    assert_true(host.commit(approval) is Ok(_))
    assert_eq(allocator.calls, 2)
    assert_eq(host.phase(), @expansion.Committed)
    assert_true(host.commit(approval) is Err(@expansion.InvalidPhase))
    let snapshot = backend.state().unwrap()
    assert_eq(snapshot.revision, 2L)
    assert_eq(snapshot.tasks.length(), 3)
    assert_eq(snapshot.attempts.length(), 0)
    assert_eq(snapshot.expansions.length(), 1)
    assert_eq(snapshot.expansions[0].mapping.length(), 2)
    assert_eq(snapshot.expansions[0].expansion_id.value, "proposal-1")
    let mapping = host.mapping()
    mapping.clear()
    assert_eq(host.mapping().length(), 2)
    let tasks = snapshot.tasks.filter(task => task.id.value != "parent")
    assert_true(tasks.all(task => task.stage is @domain.Created))
    assert_true(tasks.all(task => task.definition_of_done == ["Reviewed"]))
    let outlook = host.outlook().unwrap()
    assert_eq(outlook.length(), 2)
    assert_true(
      outlook.all(row => {
        row.stage_created &&
        row.queued_execute_attempts == 0 &&
        row.outside_workflow_task_scope &&
        !row.unexpected_state
      }),
    )
    assert_true(outlook.all(row => row.class is @expansion.Blocked(_)))
    assert_eq(
      backend
      .event_history()
      .filter(event => event.kind == "board.graph.expanded")
      .length(),
      1,
    )
    backend.shutdown()
  })
}

///|
async test "pure DAG and scope rejection leaves all state and allocations untouched" {
  @async.with_task_group(group => {
    let backend = board(group)
    let before = backend.state().unwrap()
    let bad = [
      payload(tasks=[
        task_json("a", dependencies=[{ "local": "b" }]),
        task_json("b", dependencies=[{ "local": "a" }]),
      ]),
      payload(tasks=[task_json("a", dependencies=[{ "local": "a" }])]),
      payload(tasks=[task_json("a", dependencies=[{ "local": "missing" }])]),
      payload(tasks=[task_json("a", dependencies=[{ "existing": "missing" }])]),
      payload(tasks=[
        task_json("a", dependencies=[{ "local": "b" }, { "local": "b" }]),
        task_json("b"),
      ]),
      payload(tasks=[task_json("a"), task_json("a")]),
      payload(tasks=[
        task_json("a", dependencies=[
          { "existing": "parent" },
          { "existing": "parent" },
        ]),
      ]),
    ]
    for text in bad {
      let allocator : CountingAllocator = { calls: 0, }
      let host = @expansion.ExpansionHost(backend~, allocator~, now_ms=() => {
        100L
      })
      assert_true(
        host.prepare(
          text,
          authorization=Some(authority(deps=["parent", "missing"])),
        )
        is Err(_),
      )
      assert_eq(allocator.calls, 0)
      assert_eq(backend.state().unwrap(), before)
    }
    // Forward local references accepted by the same domain whole-DAG preview.
    let host = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
    assert_true(
      host.prepare(
        payload(tasks=[
          task_json("a", dependencies=[{ "local": "b" }]),
          task_json("b"),
        ]),
        authorization=Some(authority()),
      )
      is Ok(_),
    )
    // An existing task and a local key of the same spelling remain disjoint.
    let host = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
    assert_true(
      host.prepare(
        payload(tasks=[
          task_json("parent", dependencies=[{ "existing": "parent" }]),
        ]),
        authorization=Some(authority()),
      )
      is Ok(_),
    )
    assert_eq(backend.state().unwrap(), before)
    backend.shutdown()
  })
}

///|
async test "default denial scope separation deadline and single-use per-proposal authority" {
  @async.with_task_group(group => {
    let backend = board(group)
    let denied = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
    assert_true(denied.prepare(payload()) is Err(@expansion.DefaultDenied))
    let invalid = [
      authority(workflow=""),
      authority(workflow="has space"),
      authority(scope=[]),
      // The parent must lie inside the frozen workflow task scope.
      authority(scope=["other"]),
      authority(scope=["parent", "parent"]),
      authority(deadline=100L),
      authority(deps=[]),
      authority(tasks=1),
      authority(edges=1),
      // Scope/dependency enumeration is bounded.
      authority(
        scope=Array::makei(201, i => if i == 0 { "parent" } else { "s\{i}" }),
      ),
    ]
    for auth in invalid {
      let host = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
      assert_true(
        host.prepare(payload(), authorization=Some(auth)) is Err(_),
        msg="authority must be rejected",
      )
    }
    // A clock before the epoch is expired like any other deadline violation.
    let negative = @expansion.ExpansionHost(backend~, now_ms=() => -1L)
    assert_true(
      negative.prepare(payload(), authorization=Some(authority()))
      is Err(@expansion.Expired),
    )
    let auth = authority()
    let first = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
    assert_true(first.prepare("not json", authorization=Some(auth)) is Err(_))
    let second = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
    assert_true(
      second.prepare(payload(), authorization=Some(auth))
      is Err(@expansion.DefaultDenied),
    )
    let clock = Ref(100L)
    let host = @expansion.ExpansionHost(backend~, now_ms=() => clock.val)
    assert_true(
      host.prepare(payload(), authorization=Some(authority())) is Ok(_),
    )
    let preview = host.preview().unwrap()
    let approval = host
      .approve(preview, HostApprover::{ grant: true, })
      .unwrap()
    clock.val = 1000L
    assert_true(host.commit(approval) is Err(@expansion.Expired))
    assert_eq(host.mapping(), [])
    assert_eq(backend.state().unwrap().tasks.length(), 1)
    backend.shutdown()
  })
}

///|
async test "approval cannot be swapped forged by content equality or denied implicitly" {
  @async.with_task_group(group => {
    let backend = board(group)
    let first = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
    let second = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
    assert_true(
      first.prepare(payload(), authorization=Some(authority())) is Ok(_),
    )
    assert_true(
      second.prepare(payload(), authorization=Some(authority())) is Ok(_),
    )
    let a = first.preview().unwrap()
    let b = second.preview().unwrap()
    assert_eq(a.digest, b.digest)
    assert_true(
      first.approve(b, HostApprover::{ grant: true, })
      is Err(@expansion.ApprovalMismatch),
    )
    let approval = first.approve(a, HostApprover::{ grant: true, }).unwrap()
    let other = second.approve(b, HostApprover::{ grant: true, }).unwrap()
    assert_true(first.commit(other) is Err(@expansion.ApprovalMismatch))
    assert_eq(first.phase(), @expansion.Approved)
    assert_true(first.commit(approval) is Ok(_))
    assert_true(second.commit(other) is Err(@expansion.DuplicateProposal))
    let denied = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
    assert_true(
      denied.prepare(
        payload(proposal="denied", revision=2),
        authorization=Some(authority()),
      )
      is Ok(_),
    )
    let preview = denied.preview().unwrap()
    assert_true(
      denied.approve(preview, HostApprover::{ grant: false, })
      is Err(@expansion.HostDenied),
    )
    assert_eq(denied.phase(), @expansion.Rejected)
    backend.shutdown()
  })
}

///|
async test "stale revision and cumulative workflow budgets never allocate or partly commit" {
  @async.with_task_group(group => {
    let backend = board(group)
    let allocator : CountingAllocator = { calls: 0, }
    let stale = @expansion.ExpansionHost(backend~, allocator~, now_ms=() => 100L)
    assert_true(
      stale.prepare(payload(), authorization=Some(authority())) is Ok(_),
    )
    let approval = stale
      .approve(stale.preview().unwrap(), HostApprover::{ grant: true, })
      .unwrap()
    let winner = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
    assert_true(
      winner.prepare(
        payload(proposal="winner"),
        authorization=Some(authority()),
      )
      is Ok(_),
    )
    assert_true(
      winner.commit(
        winner
        .approve(winner.preview().unwrap(), HostApprover::{ grant: true, })
        .unwrap(),
      )
      is Ok(_),
    )
    assert_true(stale.commit(approval) is Err(@expansion.StalePreview))
    assert_eq(allocator.calls, 0)
    assert_eq(backend.state().unwrap().tasks.length(), 3)
    for
      policy in [
        @expansion.ExpansionPolicy(max_workflow_expansions=1),
        @expansion.ExpansionPolicy(max_workflow_tasks=3),
      ] {
      let host = @expansion.ExpansionHost(backend~, policy~, now_ms=() => 100L)
      assert_true(
        host.prepare(
          payload(proposal="over-budget", revision=2),
          authorization=Some(authority()),
        )
        is Err(@expansion.PolicyBudgetExceeded("workflow budget")),
      )
    }
    let different_workflow = @expansion.ExpansionHost(
      backend~,
      policy=@expansion.ExpansionPolicy(max_workflow_expansions=1),
      now_ms=() => 100L,
    )
    assert_true(
      different_workflow.prepare(
        payload(proposal="other-workflow", revision=2),
        authorization=Some(authority(workflow="different")),
      )
      is Ok(_),
    )
    backend.shutdown()
  })
}

///|
struct AmbiguousStore {
  inner : @store.MemoryBoardStore
  mut mode : Int32
  mut writes : Int32
}

///|
impl @store.BoardStore for AmbiguousStore with fn load(self) {
  self.inner.load()
}

///|
impl @store.BoardStore for AmbiguousStore with fn persist(
  self,
  snapshot,
  events,
) {
  self.writes += 1
  if self.mode == 3 {
    return Err(@store.Io("injected pre-write failure"))
  }
  if self.mode != 2 {
    match self.inner.persist(snapshot, events) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
  }
  if self.mode == 1 || self.mode == 2 {
    Err(@store.DurabilityUncertain("injected uncertainty"))
  } else {
    Ok(())
  }
}

///|
async test "durability uncertainty freezes whole mapping and reconciles without any replay" {
  for mode in [1, 2] {
    @async.with_task_group(group => {
      let store : AmbiguousStore = {
        inner: @store.MemoryBoardStore(),
        mode: 0,
        writes: 0,
      }
      let backend = @backend.BoardBackend(store~, now_ms=() => 100L)
      backend.attach(group)
      create_parent(backend)
      let allocator : CountingAllocator = { calls: 0, }
      let host = @expansion.ExpansionHost(backend~, allocator~, now_ms=() => {
        100L
      })
      assert_true(
        host.prepare(payload(), authorization=Some(authority())) is Ok(_),
      )
      let approval = host
        .approve(host.preview().unwrap(), HostApprover::{ grant: true, })
        .unwrap()
      store.mode = mode
      assert_true(host.commit(approval) is Err(@expansion.Backend(_)))
      assert_eq(host.phase(), @expansion.Uncertain)
      assert_eq(allocator.calls, 2)
      assert_eq(store.writes, 2) // one parent transaction, one whole proposal
      let mapping = host.mapping()
      assert_eq(mapping.length(), 2)
      assert_true(host.commit(approval) is Err(@expansion.InvalidPhase))
      let landed = mode == 1
      assert_eq(host.reconcile().unwrap(), landed)
      assert_eq(host.mapping(), mapping)
      assert_eq(allocator.calls, 2)
      assert_eq(store.writes, 2)
      let snapshot = backend.state().unwrap()
      assert_eq(snapshot.tasks.length(), if landed { 3 } else { 1 })
      assert_eq(snapshot.expansions.length(), if landed { 1 } else { 0 })
      assert_eq(snapshot.attempts.length(), 0)
      assert_true(snapshot.tasks.all(task => task.stage is @domain.Created))
      if !landed {
        assert_eq(host.reconcile().unwrap(), false)
      }
      assert_eq(store.writes, 2)
      store.mode = 0
      backend.shutdown()
      // Fresh backend and host recover from the store, never from a retry.
      let recovered = @backend.BoardBackend(store~, now_ms=() => 200L)
      recovered.attach(group)
      let record = @expansion.recover_expansion(recovered, "proposal-1").unwrap()
      if landed {
        let record = record.unwrap()
        assert_eq(
          record.mapping.map(pair => (pair.local_ref, pair.task_id)),
          mapping,
        )
        for
          text in [
            payload(),
            payload(
              tasks=[task_json("a", title="Conflicting content")],
              revision=2,
            ),
          ] {
          let allocator : CountingAllocator = { calls: 0, }
          let again = @expansion.ExpansionHost(backend=recovered, allocator~, now_ms=() => {
            200L
          })
          assert_true(
            again.prepare(text, authorization=Some(authority()))
            is Err(@expansion.DuplicateProposal),
          )
          assert_eq(allocator.calls, 0)
        }
      } else {
        assert_true(record is None)
      }
      assert_eq(store.writes, 2)
      recovered.shutdown()
    })
  }
}

///|
struct FixedAllocator {
  id : String
}

///|
impl @expansion.ExpansionIdAllocator for FixedAllocator with fn canonical_task_id(
  self,
  proposal_id~,
  key~,
  index~,
) {
  ignore(proposal_id)
  ignore(key)
  ignore(index)
  self.id
}

///|
async test "allocator invalid duplicate or colliding IDs cannot partially commit" {
  @async.with_task_group(group => {
    let backend = board(group)
    let before = backend.state().unwrap()
    for id in ["", "bad id", "parent", "duplicate"] {
      let allocator : FixedAllocator = { id, }
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
      assert_eq(host.phase(), @expansion.Conflict)
      assert_true(host.commit(approval) is Err(@expansion.InvalidPhase))
    }
    backend.shutdown()
  })
}

///|
struct SlowSource {
  entered : Ref[Bool]
  context : Ref[@expansion.DynamicPlanContext?]
}

///|
impl @expansion.DynamicPlanSource for SlowSource with fn generate(self, context) {
  self.entered.val = true
  self.context.val = Some(context)
  context.permitted_existing_dependencies.clear()
  @async.sleep(10)
  Ok({ payload: payload(), })
}

///|
async test "generation is bounded single use and cannot race another operation on the host" {
  @async.with_task_group(group => {
    let backend = board(group)
    let host = @expansion.ExpansionHost(
      backend~,
      policy=@expansion.ExpansionPolicy(max_tasks=4, max_edges=5),
      now_ms=() => 100L,
    )
    let source : SlowSource = { entered: Ref(false), context: Ref(None), }
    @async.with_task_group(generation => {
      let work = generation.spawn(() => {
        assert_true(
          host.generate(source, authorization=Some(authority(tasks=3, edges=4)))
          is Ok(_),
        )
      })
      while !source.entered.val {
        @async.sleep(1)
      }
      assert_true(
        host.prepare(payload(), authorization=Some(authority()))
        is Err(@expansion.Busy),
      )
      assert_true(host.preview() is Err(@expansion.Busy))
      work.wait()
    })
    let context = source.context.val.unwrap()
    assert_eq(context.workflow, Some("workflow"))
    assert_eq(context.max_new_tasks, 3)
    assert_eq(context.max_new_edges, 4)
    assert_eq(context.deadline_ms, 1000L)
    // Source mutation of the context did not remove the host's permission.
    let preview = host.preview().unwrap()
    assert_eq(preview.permitted_existing_dependencies(), ["parent"])
    assert_true(
      host.generate(source, authorization=Some(authority()))
      is Err(@expansion.InvalidPhase),
    )
    assert_eq(backend.state().unwrap().tasks.length(), 1)
    backend.shutdown()
  })
}

///|
async test "concurrent commits have one complete winner and no partial loser" {
  @async.with_task_group(group => {
    let backend = board(group)
    let first = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
    let second = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
    assert_true(
      first.prepare(payload(proposal="first"), authorization=Some(authority()))
      is Ok(_),
    )
    assert_true(
      second.prepare(
        payload(proposal="second"),
        authorization=Some(authority()),
      )
      is Ok(_),
    )
    let a = first
      .approve(first.preview().unwrap(), HostApprover::{ grant: true, })
      .unwrap()
    let b = second
      .approve(second.preview().unwrap(), HostApprover::{ grant: true, })
      .unwrap()
    let outcomes : Array[Bool] = []
    @async.with_task_group(commits => {
      let one = commits.spawn(() => outcomes.push(first.commit(a) is Ok(_)))
      let two = commits.spawn(() => outcomes.push(second.commit(b) is Ok(_)))
      one.wait()
      two.wait()
    })
    assert_eq(outcomes.filter(value => value).length(), 1)
    let snapshot = backend.state().unwrap()
    assert_eq(snapshot.revision, 2L)
    assert_eq(snapshot.tasks.length(), 3)
    assert_eq(snapshot.expansions.length(), 1)
    assert_eq(snapshot.expansions[0].mapping.length(), 2)
    assert_eq(snapshot.attempts, [])
    backend.shutdown()
  })
}

///|
struct DeniedSource {}

///|
impl @expansion.DynamicPlanSource for DeniedSource with fn generate(
  self,
  context,
) {
  ignore(self)
  ignore(context)
  Err(@expansion.Denied)
}

///|
async test "phase guards deny premature steps and denied generation spends authority" {
  @async.with_task_group(group => {
    let backend = board(group)
    let fresh = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
    assert_true(fresh.preview() is Err(@expansion.InvalidPhase))
    assert_true(fresh.reconcile() is Err(@expansion.InvalidPhase))
    assert_true(fresh.outlook() is Err(@expansion.InvalidPhase))
    // A refusing source produces nothing, yet the claimed authority is spent.
    let auth = authority()
    let denied = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
    assert_true(
      denied.generate(DeniedSource::{ }, authorization=Some(auth))
      is Err(@expansion.SourceFailed(@expansion.Denied)),
    )
    assert_eq(denied.phase(), @expansion.Rejected)
    let again = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
    assert_true(
      again.prepare(payload(), authorization=Some(auth))
      is Err(@expansion.DefaultDenied),
    )
    // Approval is one-shot per host; the committed host stays terminal.
    let host = @expansion.ExpansionHost(backend~, now_ms=() => 100L)
    assert_true(
      host.prepare(payload(), authorization=Some(authority())) is Ok(_),
    )
    let preview = host.preview().unwrap()
    assert_true(host.approve(preview, HostApprover::{ grant: true, }) is Ok(_))
    assert_true(
      host.approve(preview, HostApprover::{ grant: true, })
      is Err(@expansion.InvalidPhase),
    )
    backend.shutdown()
  })
}
