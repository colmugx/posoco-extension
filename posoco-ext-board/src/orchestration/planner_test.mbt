///|
/// Detached planner fixtures built through public domain record
/// constructors; records are preserved verbatim, so shuffled orders and
/// ties stay legal snapshot input.
fn planner_task(
  id~ : String,
  stage~ : @domain.BoardStage = @domain.Ready,
  priority~ : @domain.BoardPriority = @domain.Normal,
  created_at_ms~ : Int64 = 1L,
  dependencies~ : Array[@domain.BoardTaskId] = [],
) -> @domain.BoardTask {
  @domain.BoardTask::from_record(
    id=@domain.BoardTaskId(id),
    title="task \{id}",
    description="planner fixture",
    stage~,
    priority~,
    definition_of_done=[],
    dependencies~,
    created_at_ms~,
    updated_at_ms=created_at_ms,
    ready_since_ms=None,
  )
}

///|
fn planner_attempt(
  id~ : String,
  task~ : String,
  kind~ : @domain.AttemptKind = @domain.Execute,
  status~ : @domain.AttemptStatus = @domain.Queued,
  created_at_ms~ : Int64 = 1L,
) -> @domain.Attempt {
  @domain.Attempt::from_record(
    id=@domain.AttemptId(id),
    task_id=@domain.BoardTaskId(task),
    kind~,
    status~,
    review=None,
    created_at_ms~,
    started_at_ms=None,
    finished_at_ms=None,
    updated_at_ms=created_at_ms,
  )
}

///|
fn planner_snapshot(
  revision~ : Int64 = 0L,
  tasks~ : Array[@domain.BoardTask] = [],
  attempts~ : Array[@domain.Attempt] = [],
) -> @domain.BoardStateSnapshot {
  { revision, tasks, attempts, expansions: [], }
}

///|
fn available_input(
  task_id~ : String,
  attempt_id~ : String,
) -> @orchestration.ExecutionInputAvailability {
  { task_id, attempt_id, status: @orchestration.Available, }
}

///|
fn denied_input(
  task_id~ : String,
  attempt_id~ : String,
) -> @orchestration.ExecutionInputAvailability {
  { task_id, attempt_id, status: @orchestration.Denied, }
}

///|
fn missing_input(
  task_id~ : String,
  attempt_id~ : String,
) -> @orchestration.ExecutionInputAvailability {
  { task_id, attempt_id, status: @orchestration.Missing, }
}

///|
/// Ready task plus one queued Execute Attempt plus its Available input: the
/// minimal admissible row sharing one id.
fn admissible_row(
  id~ : String,
  priority~ : @domain.BoardPriority = @domain.Normal,
  created_at_ms~ : Int64 = 1L,
) -> (
  @domain.BoardTask,
  @domain.Attempt,
  @orchestration.ExecutionInputAvailability,
) {
  let attempt_id = "attempt-\{id}"
  (
    planner_task(id~, priority~, created_at_ms~),
    planner_attempt(id=attempt_id, task=id, created_at_ms~),
    available_input(task_id=id, attempt_id~),
  )
}

///|
/// Plans with admission enabled and no input metadata unless overridden.
fn plan_of(
  snapshot : @domain.BoardStateSnapshot,
  policy~ : @orchestration.ExecutionPolicy = @orchestration.ExecutionPolicy(
    enabled=true,
  ),
  inputs~ : Array[@orchestration.ExecutionInputAvailability] = [],
) -> @orchestration.ExecutionPlan {
  @orchestration.plan_execution(snapshot, policy, inputs)
}

///|
/// Applies one accepted command through the public propose API; planner
/// fixtures never exercise rejections.
fn apply(
  state : @domain.BoardState,
  command : @domain.BoardCommand,
) -> @domain.BoardState {
  @domain.BoardDomain::propose(state, command).unwrap().next_state
}

///|
/// Creates one task through the public propose API.
fn propose_created(
  state : @domain.BoardState,
  id~ : String,
  dependencies~ : Array[@domain.BoardTaskId] = [],
) -> @domain.BoardState {
  apply(
    state,
    @domain.CreateTask(
      id=@domain.BoardTaskId(id),
      title="task \{id}",
      description="planner fixture",
      priority=@domain.Normal,
      definition_of_done=[],
      dependencies~,
      at_ms=0L,
      expected_revision=state.revision(),
    ),
  )
}

///|
/// Drives one propose-built task from Created through `stages`.
fn propose_moved(
  state : @domain.BoardState,
  id~ : String,
  stages~ : Array[@domain.BoardStage],
) -> @domain.BoardState {
  let mut current = state
  for stage in stages {
    current = apply(
      current,
      @domain.MoveTask(
        id=@domain.BoardTaskId(id),
        to=stage,
        at_ms=current.revision(),
        expected_revision=current.revision(),
      ),
    )
  }
  current
}

///|
/// Queues one Execute Attempt through the public propose API.
fn propose_queued(
  state : @domain.BoardState,
  attempt_id~ : String,
  task_id~ : String,
) -> @domain.BoardState {
  apply(
    state,
    @domain.QueueAttempt(
      id=@domain.AttemptId(attempt_id),
      task=@domain.BoardTaskId(task_id),
      kind=@domain.Execute,
      at_ms=state.revision(),
      expected_revision=state.revision(),
    ),
  )
}

///|
test "empty board plans neither eligible nor blocked rows" {
  let plan = plan_of(planner_snapshot(revision=7L))
  assert_eq(plan.revision, 7L)
  assert_eq(plan.policy_id, "ready-dependencies-done-v1")
  assert_eq(plan.eligible, [])
  assert_eq(plan.blocked, [])
}

///|
test "admission is opt-in: the disabled default blocks otherwise eligible tasks" {
  assert_false(@orchestration.ExecutionPolicy().enabled)
  let (task, attempt, input) = admissible_row(id="task-1")
  let plan = plan_of(
    planner_snapshot(tasks=[task], attempts=[attempt]),
    policy=@orchestration.ExecutionPolicy(),
    inputs=[input],
  )
  assert_eq(plan.eligible, [])
  assert_eq(plan.blocked, [
    {
      task_id: "task-1",
      attempt_id: Some("attempt-task-1"),
      reasons: [@orchestration.AdmissionDisabled],
    },
  ])
}

///|
test "propose-built Ready task with queued Execute Attempt becomes eligible" {
  let base = propose_created(@domain.BoardState::BoardState(), id="task-1")
  let ready = propose_moved(base, id="task-1", stages=[
    @domain.Refining,
    @domain.Ready,
  ])
  let queued = propose_queued(ready, attempt_id="attempt-1", task_id="task-1")
  let snapshot = queued.snapshot()
  assert_eq(snapshot.revision, 4L)
  let plan = plan_of(snapshot, inputs=[
    available_input(task_id="task-1", attempt_id="attempt-1"),
  ])
  assert_eq(plan.revision, 4L)
  assert_eq(plan.eligible, [{ task_id: "task-1", attempt_id: "attempt-1", }])
  assert_eq(plan.blocked, [])
}

///|
test "dependencies stop blocking only at Done" {
  let created = propose_created(@domain.BoardState::BoardState(), id="task-dep")
  let seeded = propose_created(created, id="task-main", dependencies=[
    @domain.BoardTaskId("task-dep"),
  ])
  let reviewed = propose_moved(seeded, id="task-dep", stages=[
    @domain.Refining,
    @domain.Ready,
    @domain.Running,
    @domain.Review,
  ])
  let readied = propose_moved(reviewed, id="task-main", stages=[
    @domain.Refining,
    @domain.Ready,
  ])
  let queued = propose_queued(
    readied,
    attempt_id="attempt-main",
    task_id="task-main",
  )
  let input = available_input(task_id="task-main", attempt_id="attempt-main")
  let review_plan = plan_of(queued.snapshot(), inputs=[input])
  assert_eq(review_plan.eligible, [])
  assert_eq(review_plan.blocked, [
    {
      task_id: "task-dep",
      attempt_id: None,
      reasons: [
        @orchestration.TaskStageIneligible,
        @orchestration.NoQueuedExecuteAttempt,
      ],
    },
    {
      task_id: "task-main",
      attempt_id: Some("attempt-main"),
      reasons: [@orchestration.DependencyNotDone("task-dep")],
    },
  ])
  let done = apply(
    queued,
    @domain.MoveTask(
      id=@domain.BoardTaskId("task-dep"),
      to=@domain.Done,
      at_ms=queued.revision(),
      expected_revision=queued.revision(),
    ),
  )
  let done_plan = plan_of(done.snapshot(), inputs=[input])
  assert_eq(done_plan.eligible, [
    { task_id: "task-main", attempt_id: "attempt-main", },
  ])
  assert_eq(done_plan.blocked, [
    {
      task_id: "task-dep",
      attempt_id: None,
      reasons: [
        @orchestration.TaskStageIneligible,
        @orchestration.NoQueuedExecuteAttempt,
      ],
    },
  ])
}

///|
test "dependency reasons follow sorted ids; Done dependencies stay silent" {
  let tasks = [
    planner_task(id="task-b"),
    planner_task(id="task-c", stage=@domain.Done),
    planner_task(id="task-main", dependencies=[
      @domain.BoardTaskId("task-c"),
      @domain.BoardTaskId("task-a"),
      @domain.BoardTaskId("task-b"),
      @domain.BoardTaskId("task-b"),
    ]),
  ]
  let plan = plan_of(
    planner_snapshot(tasks~, attempts=[
      planner_attempt(id="attempt-main", task="task-main"),
    ]),
    inputs=[available_input(task_id="task-main", attempt_id="attempt-main")],
  )
  assert_eq(plan.eligible, [])
  assert_eq(plan.blocked, [
    {
      task_id: "task-b",
      attempt_id: None,
      reasons: [@orchestration.NoQueuedExecuteAttempt],
    },
    {
      task_id: "task-c",
      attempt_id: None,
      reasons: [
        @orchestration.TaskStageIneligible,
        @orchestration.NoQueuedExecuteAttempt,
      ],
    },
    {
      task_id: "task-main",
      attempt_id: Some("attempt-main"),
      reasons: [
        @orchestration.MissingDependency("task-a"),
        @orchestration.DependencyNotDone("task-b"),
        @orchestration.DependencyNotDone("task-b"),
      ],
    },
  ])
}

///|
test "policy stage allowlist decides which stages are eligible" {
  let tasks = [
    planner_task(id="task-created", stage=@domain.Created),
    planner_task(id="task-ready"),
    planner_task(id="task-running", stage=@domain.Running),
  ]
  let attempts = [
    planner_attempt(id="attempt-created", task="task-created"),
    planner_attempt(id="attempt-ready", task="task-ready"),
    planner_attempt(id="attempt-running", task="task-running"),
  ]
  let inputs = [
    available_input(task_id="task-created", attempt_id="attempt-created"),
    available_input(task_id="task-ready", attempt_id="attempt-ready"),
    available_input(task_id="task-running", attempt_id="attempt-running"),
  ]
  let snapshot = planner_snapshot(tasks~, attempts~)
  let ready_only = plan_of(snapshot, inputs~)
  assert_eq(ready_only.eligible, [
    { task_id: "task-ready", attempt_id: "attempt-ready", },
  ])
  assert_eq(ready_only.blocked, [
    {
      task_id: "task-created",
      attempt_id: Some("attempt-created"),
      reasons: [@orchestration.TaskStageIneligible],
    },
    {
      task_id: "task-running",
      attempt_id: Some("attempt-running"),
      reasons: [@orchestration.TaskStageIneligible],
    },
  ])
  let wide = @orchestration.ExecutionPolicy(enabled=true, stages=[
    @domain.Created,
    @domain.Running,
  ])
  let wide_plan = plan_of(snapshot, policy=wide, inputs~)
  assert_eq(wide_plan.eligible, [
    { task_id: "task-created", attempt_id: "attempt-created", },
    { task_id: "task-running", attempt_id: "attempt-running", },
  ])
  assert_eq(wide_plan.blocked, [
    {
      task_id: "task-ready",
      attempt_id: Some("attempt-ready"),
      reasons: [@orchestration.TaskStageIneligible],
    },
  ])
}

///|
test "eligible rows order by priority descending then creation time then id ascending" {
  let rows = [
    admissible_row(id="task-zeta", created_at_ms=300L),
    admissible_row(id="task-low", priority=@domain.Low, created_at_ms=1L),
    admissible_row(
      id="task-high-late",
      priority=@domain.High,
      created_at_ms=800L,
    ),
    admissible_row(
      id="task-critical",
      priority=@domain.Critical,
      created_at_ms=900L,
    ),
    admissible_row(id="task-mid", created_at_ms=300L),
    admissible_row(
      id="task-high-early",
      priority=@domain.High,
      created_at_ms=100L,
    ),
  ]
  let plan = plan_of(
    planner_snapshot(
      tasks=rows.map(row => row.0),
      attempts=rows.map(row => row.1),
    ),
    inputs=rows.map(row => row.2),
  )
  assert_eq(plan.blocked, [])
  assert_eq(plan.eligible, [
    { task_id: "task-critical", attempt_id: "attempt-task-critical", },
    { task_id: "task-high-early", attempt_id: "attempt-task-high-early", },
    { task_id: "task-high-late", attempt_id: "attempt-task-high-late", },
    { task_id: "task-mid", attempt_id: "attempt-task-mid", },
    { task_id: "task-zeta", attempt_id: "attempt-task-zeta", },
    { task_id: "task-low", attempt_id: "attempt-task-low", },
  ])
}

///|
test "only queued Execute Attempts on the same task qualify" {
  let plan = plan_of(
    planner_snapshot(
      tasks=[planner_task(id="task-1"), planner_task(id="task-2")],
      attempts=[
        planner_attempt(
          id="attempt-running",
          task="task-1",
          status=@domain.Running,
        ),
        planner_attempt(
          id="attempt-discuss",
          task="task-1",
          kind=@domain.Discuss,
        ),
        planner_attempt(id="attempt-review", task="task-1", kind=@domain.Review),
        planner_attempt(id="attempt-ok", task="task-2"),
      ],
    ),
    inputs=[available_input(task_id="task-2", attempt_id="attempt-ok")],
  )
  assert_eq(plan.eligible, [{ task_id: "task-2", attempt_id: "attempt-ok", }])
  assert_eq(plan.blocked, [
    {
      task_id: "task-1",
      attempt_id: None,
      reasons: [@orchestration.NoQueuedExecuteAttempt],
    },
  ])
}

///|
test "multiple queued Execute Attempts yield one candidate: oldest then lowest id" {
  let snapshot = planner_snapshot(tasks=[planner_task(id="task-1")], attempts=[
    planner_attempt(id="attempt-c", task="task-1", created_at_ms=300L),
    planner_attempt(id="attempt-b", task="task-1", created_at_ms=200L),
    planner_attempt(id="attempt-newest", task="task-1", created_at_ms=400L),
    planner_attempt(id="attempt-a", task="task-1", created_at_ms=200L),
  ])
  let plan = plan_of(snapshot, inputs=[
    available_input(task_id="task-1", attempt_id="attempt-a"),
  ])
  assert_eq(plan.eligible, [{ task_id: "task-1", attempt_id: "attempt-a", }])
  assert_eq(plan.blocked, [])
  // Availability is consulted for the preferred Attempt only: a Denied row
  // for a newer Attempt neither flips the choice nor adds a slot.
  let denied_newer = plan_of(snapshot, inputs=[
    available_input(task_id="task-1", attempt_id="attempt-a"),
    denied_input(task_id="task-1", attempt_id="attempt-newest"),
  ])
  assert_eq(denied_newer, plan)
}

///|
test "input availability fails closed on missing, conflicting and denied metadata" {
  let snapshot = planner_snapshot(tasks=[planner_task(id="task-1")], attempts=[
    planner_attempt(id="attempt-1", task="task-1"),
  ])
  let no_metadata = plan_of(snapshot)
  assert_eq(no_metadata.eligible, [])
  assert_eq(no_metadata.blocked, [
    {
      task_id: "task-1",
      attempt_id: Some("attempt-1"),
      reasons: [@orchestration.MissingExecutionInput],
    },
  ])
  let other_attempt = plan_of(snapshot, inputs=[
    available_input(task_id="task-1", attempt_id="attempt-other"),
  ])
  assert_eq(other_attempt.blocked[0].reasons, [
    @orchestration.MissingExecutionInput,
  ])
  let not_available = plan_of(snapshot, inputs=[
    missing_input(task_id="task-1", attempt_id="attempt-1"),
  ])
  assert_eq(not_available.blocked[0].reasons, [
    @orchestration.MissingExecutionInput,
  ])
  let duplicated = plan_of(snapshot, inputs=[
    available_input(task_id="task-1", attempt_id="attempt-1"),
    available_input(task_id="task-1", attempt_id="attempt-1"),
  ])
  assert_eq(duplicated.blocked[0].reasons, [
    @orchestration.MissingExecutionInput,
  ])
  let denied = plan_of(snapshot, inputs=[
    denied_input(task_id="task-1", attempt_id="attempt-1"),
    available_input(task_id="task-1", attempt_id="attempt-1"),
  ])
  assert_eq(denied.blocked[0].reasons, [@orchestration.AuthorizationDenied])
  let admitted = plan_of(snapshot, inputs=[
    available_input(task_id="task-1", attempt_id="attempt-1"),
  ])
  assert_eq(admitted.eligible, [{ task_id: "task-1", attempt_id: "attempt-1", }])
}

///|
test "policy copies its stage allowlist at construction and on every read" {
  let stages = [@domain.Ready]
  let policy = @orchestration.ExecutionPolicy(
    enabled=true,
    stages~,
    id="stage-matrix-v2",
  )
  stages.push(@domain.Running)
  assert_eq(policy.stages(), [@domain.Ready])
  let returned = policy.stages()
  returned.push(@domain.Done)
  assert_eq(policy.stages(), [@domain.Ready])
  let snapshot = planner_snapshot(
    tasks=[
      planner_task(id="task-ready"),
      planner_task(id="task-running", stage=@domain.Running),
    ],
    attempts=[
      planner_attempt(id="attempt-ready", task="task-ready"),
      planner_attempt(id="attempt-running", task="task-running"),
    ],
  )
  let inputs = [
    available_input(task_id="task-ready", attempt_id="attempt-ready"),
    available_input(task_id="task-running", attempt_id="attempt-running"),
  ]
  let plan = plan_of(snapshot, policy~, inputs~)
  assert_eq(plan.policy_id, "stage-matrix-v2")
  assert_eq(plan.eligible, [
    { task_id: "task-ready", attempt_id: "attempt-ready", },
  ])
  assert_eq(plan.blocked, [
    {
      task_id: "task-running",
      attempt_id: Some("attempt-running"),
      reasons: [@orchestration.TaskStageIneligible],
    },
  ])
}

///|
test "planning is deterministic for identical inputs" {
  let snapshot = planner_snapshot(
    revision=11L,
    tasks=[
      planner_task(id="task-stage", stage=@domain.Running, created_at_ms=200L),
      planner_task(id="task-noattempts", created_at_ms=150L),
      planner_task(id="task-eligible", created_at_ms=100L),
      planner_task(id="task-deps", created_at_ms=50L, dependencies=[
        @domain.BoardTaskId("task-gone"),
      ]),
    ],
    attempts=[
      planner_attempt(id="attempt-stage", task="task-stage", created_at_ms=200L),
      planner_attempt(
        id="attempt-eligible",
        task="task-eligible",
        created_at_ms=100L,
      ),
      planner_attempt(id="attempt-deps", task="task-deps", created_at_ms=50L),
    ],
  )
  let inputs = [
    available_input(task_id="task-stage", attempt_id="attempt-stage"),
    available_input(task_id="task-eligible", attempt_id="attempt-eligible"),
    available_input(task_id="task-deps", attempt_id="attempt-deps"),
  ]
  let expected : @orchestration.ExecutionPlan = {
    revision: 11L,
    policy_id: "ready-dependencies-done-v1",
    eligible: [{ task_id: "task-eligible", attempt_id: "attempt-eligible", }],
    blocked: [
      {
        task_id: "task-deps",
        attempt_id: Some("attempt-deps"),
        reasons: [@orchestration.MissingDependency("task-gone")],
      },
      {
        task_id: "task-noattempts",
        attempt_id: None,
        reasons: [@orchestration.NoQueuedExecuteAttempt],
      },
      {
        task_id: "task-stage",
        attempt_id: Some("attempt-stage"),
        reasons: [@orchestration.TaskStageIneligible],
      },
    ],
  }
  let first = plan_of(snapshot, inputs~)
  let second = plan_of(snapshot, inputs~)
  assert_eq(first, expected)
  assert_eq(second, expected)
}

///|
test "planning leaves the snapshot and input arrays untouched" {
  let snapshot = planner_snapshot(
    revision=11L,
    tasks=[
      planner_task(id="task-b", priority=@domain.Low, created_at_ms=9L, dependencies=[
        @domain.BoardTaskId("task-a"),
      ]),
      planner_task(
        id="task-a",
        priority=@domain.Critical,
        stage=@domain.Done,
        created_at_ms=2L,
      ),
    ],
    attempts=[
      planner_attempt(id="attempt-b", task="task-b", created_at_ms=9L),
      planner_attempt(id="attempt-z", task="task-b", created_at_ms=4L),
    ],
  )
  let inputs = [
    available_input(task_id="task-b", attempt_id="attempt-z"),
    denied_input(task_id="task-a", attempt_id="attempt-gone"),
  ]
  let snapshot_before = snapshot.copy_detached()
  let inputs_before = inputs.copy()
  let plan = plan_of(snapshot, inputs~)
  assert_eq(plan.eligible, [{ task_id: "task-b", attempt_id: "attempt-z", }])
  assert_eq(snapshot, snapshot_before)
  assert_eq(inputs, inputs_before)
  // The stored order itself is preserved, not merely an equal deep copy.
  assert_eq(snapshot.tasks.map(task => task.id.value), ["task-b", "task-a"])
  assert_eq(snapshot.attempts.map(attempt => attempt.id.value), [
    "attempt-b", "attempt-z",
  ])
}
