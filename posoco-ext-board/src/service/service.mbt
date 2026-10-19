///|
/// Complete, opt-in Board workflow capability. Clients provide a private
/// directory, one host scope and an Agent capability factory, not runtime
/// internals. This instance is the sole durable writer for its namespace.
pub struct BoardWorkflows {
  priv directory : String
  priv group : @async.TaskGroup[Unit]
  priv agents : &WorkflowAgentFactory
  priv policy : BoardWorkflowPolicy
  priv clock : () -> Int64
  priv authorize : () -> Bool
  priv board : @backend.BoardBackend
  priv journal : @journal.FileBoardExecutionStore
  priv channels : Array[@execution.BoardExecutionResultChannel]
  priv live : Ref[Bool]
  priv workflow : Ref[String]
  priv planning_attempt : Ref[String?]
  priv inputs : WorkflowInputs
  priv mut ui : &@posoco.UiPort?
  priv mut owner : @execution.BoardExecutionOwner?
  priv mut controller : @dynamic.DynamicWorkflowController?
  priv mut preview_ : @expansion.ExpansionApprovalPreview?
  priv mut initialized : Bool
  priv mut closed : Bool
  priv mut busy : Bool
  priv mut operation : @async.Task[Unit]?
  priv mut stopped : Bool
  priv mut paused : Bool
  priv mut unresolved : Bool
  priv mut uncertain : Bool
  priv mut deadline : Int64?
  priv mut counter : Int32
}

///|
pub fn BoardWorkflows::BoardWorkflows(
  directory~ : String,
  agents~ : &WorkflowAgentFactory,
  group~ : @async.TaskGroup[Unit],
  policy~ : BoardWorkflowPolicy = BoardWorkflowPolicy(),
  now_ms~ : () -> Int64 = () => @async.now(),
  authorize~ : () -> Bool = () => true,
) -> BoardWorkflows {
  {
    directory,
    agents,
    group,
    policy,
    clock: now_ms,
    authorize,
    board: @backend.BoardBackend(
      store=@store.FileBoardStore::at_directory(directory~),
      now_ms~,
    ),
    journal: @journal.FileBoardExecutionStore(directory~),
    channels: Array::makei(policy.max_concurrency.clamp(min=1, max=8), _ => {
      @execution.BoardExecutionResultChannel(max_chars=65536)
    }),
    live: Ref(false),
    workflow: Ref(""),
    planning_attempt: Ref(None),
    inputs: { values: Map([]), },
    ui: None,
    owner: None,
    controller: None,
    preview_: None,
    initialized: false,
    closed: false,
    busy: false,
    operation: None,
    stopped: false,
    paused: false,
    unresolved: false,
    uncertain: false,
    deadline: None,
    counter: 0,
  }
}

///|
fn BoardWorkflows::check(
  self : BoardWorkflows,
) -> Unit raise BoardWorkflowError {
  if self.closed || self.stopped {
    raise Closed
  }
  if !self.policy.enabled {
    raise Disabled
  }
  if !(self.authorize)() {
    raise ApprovalDenied
  }
  if self.uncertain {
    raise DurabilityUncertain
  }
  if self.unresolved {
    raise UnresolvedExecution
  }
  if self.paused {
    raise NotQuiescent
  }
  if self.deadline is Some(deadline) && (self.clock)() >= deadline {
    raise BudgetExceeded
  }
}

///|
fn BoardWorkflows::running(
  self : BoardWorkflows,
) -> @dynamic.DynamicWorkflowController raise BoardWorkflowError {
  match self.controller {
    Some(controller) => controller
    None => raise NotStarted
  }
}

///|
fn BoardWorkflows::mint(self : BoardWorkflows, kind : String) -> String {
  self.counter += 1
  (if self.workflow.val.is_empty() { "board" } else { self.workflow.val }) +
  "-" +
  kind +
  "-" +
  self.counter.to_string()
}

///|
async fn BoardWorkflows::initialize(self : BoardWorkflows) -> Unit {
  if self.initialized {
    return
  }
  if self.unresolved {
    raise UnresolvedExecution
  }
  prepare_directory(self.directory)
  let records = match self.journal.load() {
    Ok(records) => records
    Err(_) => raise StoreUnavailable
  }
  if records.any(b => b.phase != @execution.Settled) {
    self.unresolved = true
    raise UnresolvedExecution
  }
  self.board.attach(self.group)
  if self.board.wait_ready() is Err(_) {
    raise StoreUnavailable
  }
  let leases : Map[Int32, Array[&@posoco.Extension]] = Map([])
  let owner = @execution.BoardExecutionOwner::with_slots(
    backend=self.board,
    store=self.journal,
    max_concurrency=self.policy.max_concurrency,
    adapter_factory=slot => FactoryAdapter::{
      factory: self.agents,
      slot,
      workflow: self.workflow,
      planning_attempt: self.planning_attempt,
      live: self.live,
      channel: self.channels[slot],
      leases,
      authorize: self.authorize,
      inner: None,
      active: false,
    },
  )
  let owner = match owner {
    Ok(owner) => owner
    Err(_) => raise InvalidConfiguration
  }
  self.owner = Some(owner)
  if owner.attach(self.group) is Err(_) || owner.status().unresolved {
    self.unresolved = true
    raise UnresolvedExecution
  }
  self.live.val = true
  self.initialized = true
}

///|
async fn[T] BoardWorkflows::perform(
  self : BoardWorkflows,
  work : async () -> T,
  recovery~ : Bool = false,
) -> Result[T, BoardWorkflowError] {
  if self.closed {
    return Err(Closed)
  }
  if self.busy {
    return Err(Busy)
  }
  if !recovery {
    self.check() catch {
      error => return Err(safe_error(error))
    }
  }
  self.busy = true
  let result : Ref[Result[T, BoardWorkflowError]?] = Ref(None)
  let timeout = self.deadline
    .map(d => (d - (self.clock)()).max(1L).min(86400000L).to_int())
    .unwrap_or(self.policy.max_elapsed_ms)
  let task = self.group.spawn(allow_failure=true, () => {
    result.val = Some(
      Ok(@async.with_timeout(timeout, work)) catch {
        error => Err(safe_error(error))
      },
    )
  })
  self.operation = Some(task)
  let waited = @async.handle_cancellation(() => {
    task.wait()
    true
  }) catch {
    _ => Some(false)
  }
  if waited != Some(true) {
    task.cancel()
    if !@async.protect_from_cancel(() => settle_operation(task, 4000)) {
      self.unresolved = true
      return Err(UnresolvedExecution)
    }
  }
  self.operation = None
  self.busy = false
  result.val.unwrap_or(Err(OperationRejected))
}

///|
async fn settle_operation(task : @async.Task[Unit], timeout : Int32) -> Bool {
  @async.with_timeout(timeout, () => {
    task.wait() catch {
      _ => ()
    }
    true
  }) catch {
    _ => false
  }
}

///|
fn safe_error(error : Error) -> BoardWorkflowError {
  match error {
    BoardWorkflowError::Disabled => Disabled
    BoardWorkflowError::InvalidConfiguration => InvalidConfiguration
    BoardWorkflowError::MissingUi => MissingUi
    BoardWorkflowError::Closed => Closed
    BoardWorkflowError::Busy => Busy
    BoardWorkflowError::NotStarted => NotStarted
    BoardWorkflowError::ApprovalDenied => ApprovalDenied
    BoardWorkflowError::RevisionConflict => RevisionConflict
    BoardWorkflowError::InvalidProposal => InvalidProposal
    BoardWorkflowError::AgentUnavailable => AgentUnavailable
    BoardWorkflowError::StoreUnavailable => StoreUnavailable
    BoardWorkflowError::DurabilityUncertain => DurabilityUncertain
    BoardWorkflowError::UnresolvedExecution => UnresolvedExecution
    BoardWorkflowError::BudgetExceeded => BudgetExceeded
    BoardWorkflowError::NotQuiescent => NotQuiescent
    BoardWorkflowError::PreparationBlocked => PreparationBlocked
    _ => OperationRejected
  }
}

///|
async fn BoardWorkflows::confirm(
  self : BoardWorkflows,
  prompt : String,
) -> Unit {
  let ui = match self.ui {
    Some(ui) => ui
    None => raise MissingUi
  }
  let response = ui.request(@posoco.UiRequest::Confirm(prompt~)) catch {
    _ => raise ApprovalDenied
  }
  self.check()
  if response != @posoco.UiResponse::Yes {
    raise ApprovalDenied
  }
}

///|
async fn BoardWorkflows::submit(
  self : BoardWorkflows,
  command : @domain.BoardCommand,
) -> Unit {
  self.check()
  self.uncertain = true
  let result = @async.protect_from_cancel(() => self.board.submit(command))
  match result {
    Ok(_) => self.uncertain = false
    Err(@coordinator.Rejected(@domain.RevisionConflict(..))) => {
      self.uncertain = false
      raise RevisionConflict
    }
    Err(@coordinator.Rejected(_)) | Err(@coordinator.PersistFailed(_)) => {
      self.uncertain = false
      raise OperationRejected
    }
    Err(_) => raise DurabilityUncertain
  }
}

///|
async fn BoardWorkflows::snapshot(
  self : BoardWorkflows,
) -> @domain.BoardStateSnapshot {
  match self.board.state() {
    Ok(snapshot) => snapshot
    Err(_) => raise StoreUnavailable
  }
}

///|
fn BoardWorkflows::discard_settled_results(self : BoardWorkflows) -> Unit {
  if self.owner is Some(owner) &&
    owner.status().active_bindings.is_empty() &&
    !owner.status().admission_busy &&
    !owner.status().unresolved {
    for channel in self.channels {
      channel.discard()
    }
  }
}
