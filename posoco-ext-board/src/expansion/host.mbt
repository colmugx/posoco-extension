///|
/// One bounded proposal per host. No runtime, task execution or stage mutation.
/// Synchronous busy admission spans every await and approver callback.
pub struct ExpansionHost {
  priv backend_ : @backend.BoardBackend
  priv policy_ : ExpansionPolicy
  priv allocator_ : &ExpansionIdAllocator
  priv now_ms_ : () -> Int64
  priv mut busy_ : Bool
  priv mut phase_ : ExpansionPhase
  priv mut authorization_ : ExpansionAuthorization?
  priv mut draft_ : DraftExpansion?
  priv mut preview_ : ExpansionApprovalPreview?
  priv mut approval_ : ExpansionApproval?
  priv mapping_ : Array[(String, @domain.BoardTaskId)]
  priv mut candidates_ : Array[@domain.GraphTask]
  priv mut expected_digest_ : String?
}

///|
pub fn ExpansionHost::ExpansionHost(
  backend~ : @backend.BoardBackend,
  policy~ : ExpansionPolicy = ExpansionPolicy(),
  allocator~ : &ExpansionIdAllocator = NumberedExpansionAllocator(
    prefix="expanded-",
  ),
  now_ms~ : () -> Int64 = @async.now,
) -> ExpansionHost {
  {
    backend_: backend,
    policy_: policy,
    allocator_: allocator,
    now_ms_: now_ms,
    busy_: false,
    phase_: Empty,
    authorization_: None,
    draft_: None,
    preview_: None,
    approval_: None,
    mapping_: [],
    candidates_: [],
    expected_digest_: None,
  }
}

///|
pub fn ExpansionHost::phase(self : ExpansionHost) -> ExpansionPhase {
  self.phase_
}

///|
pub fn ExpansionHost::mapping(
  self : ExpansionHost,
) -> Array[(String, @domain.BoardTaskId)] {
  self.mapping_.copy()
}

///|
async fn ExpansionHost::read_snapshot(
  self : ExpansionHost,
) -> Result[@domain.BoardStateSnapshot, ExpansionError] {
  self.backend_.state().map_err(e => Backend(e))
}

///|
async fn ExpansionHost::prepare_inner(
  self : ExpansionHost,
  payload : String,
  auth : ExpansionAuthorization,
) -> Result[Unit, ExpansionError] {
  let draft = match
    decode_expansion_proposal(payload~, policy=self.policy_).map_err(e => {
      DecodeFailed(e)
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let snapshot = match self.read_snapshot() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match
    validate_expansion(draft, snapshot, auth, self.policy_, (self.now_ms_)()) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  self.draft_ = Some(draft)
  self.phase_ = Validated
  Ok(())
}

///|
fn ExpansionHost::claim(
  self : ExpansionHost,
  authorization : ExpansionAuthorization?,
) -> Result[ExpansionAuthorization, ExpansionError] {
  if self.phase_ != Empty {
    return Err(InvalidPhase)
  }
  let auth = match authorization {
    Some(auth) => auth
    None => return Err(DefaultDenied)
  }
  match check_authority(auth, (self.now_ms_)()) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if auth.used_ {
    return Err(DefaultDenied)
  }
  auth.used_ = true
  self.authorization_ = Some(auth)
  // Failed decoding, cancellation, or source failure never replenish authority.
  self.phase_ = Rejected
  Ok(auth)
}

///|
/// Step 1a: accept untrusted payload, strictly decode and validate only.
pub async fn ExpansionHost::prepare(
  self : ExpansionHost,
  payload : String,
  authorization~ : ExpansionAuthorization? = None,
) -> Result[Unit, ExpansionError] {
  if self.busy_ {
    return Err(Busy)
  }
  self.busy_ = true
  defer {
    self.busy_ = false
  }
  let auth = match self.claim(authorization) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.prepare_inner(payload, auth)
}

///|
/// Step 1b: optional generic source. This package creates no Agent or owner.
pub async fn ExpansionHost::generate(
  self : ExpansionHost,
  source : &DynamicPlanSource,
  authorization~ : ExpansionAuthorization? = None,
) -> Result[Unit, ExpansionError] {
  if self.busy_ {
    return Err(Busy)
  }
  self.busy_ = true
  defer {
    self.busy_ = false
  }
  let auth = match self.claim(authorization) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let context : DynamicPlanContext = {
    workflow_parent: auth.parent_,
    workflow: Some(auth.workflow_),
    authorization_id: auth.authorization_id_,
    permitted_existing_dependencies: auth.dependencies_.copy(),
    max_new_tasks: Int32::min(auth.max_tasks_, self.policy_.max_tasks()),
    max_new_edges: Int32::min(auth.max_edges_, self.policy_.max_edges()),
    max_payload_bytes: self.policy_.max_payload_bytes(),
    deadline_ms: auth.deadline_ms_,
  }
  let reply = match source.generate(context).map_err(e => SourceFailed(e)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.prepare_inner(reply.payload, auth)
}

///|
/// Step 2: fresh, detached immutable preview. No canonical IDs allocated yet.
pub async fn ExpansionHost::preview(
  self : ExpansionHost,
) -> Result[ExpansionApprovalPreview, ExpansionError] {
  if self.busy_ {
    return Err(Busy)
  }
  if self.phase_ != Validated {
    return Err(InvalidPhase)
  }
  self.busy_ = true
  defer {
    self.busy_ = false
  }
  let draft = self.draft_.unwrap()
  let auth = self.authorization_.unwrap()
  let snapshot = match self.read_snapshot() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match
    validate_expansion(draft, snapshot, auth, self.policy_, (self.now_ms_)()) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let (expansions, tasks) = workflow_usage(snapshot, auth.workflow_)
  let preview : ExpansionApprovalPreview = {
    proposal_id: draft.proposal_id,
    digest: proposal_digest(draft),
    revision: draft.base_revision,
    policy: self.policy_.snapshot(),
    budgets: {
      expansions_used: expansions,
      max_expansions: self.policy_.max_workflow_expansions(),
      cumulative_tasks: tasks,
      max_cumulative_tasks: self.policy_.max_workflow_tasks(),
    },
    authorization_id: auth.authorization_id_,
    workflow: auth.workflow_,
    workflow_parent: auth.parent_,
    deadline_ms: auth.deadline_ms_,
    max_tasks: auth.max_tasks_,
    max_edges: auth.max_edges_,
    draft_: copy_draft(draft),
    scope_: auth.workflow_scope_.copy(),
    dependencies_: auth.dependencies_.copy(),
  }
  self.preview_ = Some(preview)
  self.phase_ = AwaitingApproval
  Ok(preview)
}

///|
/// Step 3: explicit host approval, exact in-process preview identity required.
pub fn ExpansionHost::approve(
  self : ExpansionHost,
  preview : ExpansionApprovalPreview,
  approver : &ExpansionApprover,
) -> Result[ExpansionApproval, ExpansionError] {
  if self.busy_ {
    return Err(Busy)
  }
  if self.phase_ != AwaitingApproval {
    return Err(InvalidPhase)
  }
  if !physical_equal(self.preview_.unwrap(), preview) {
    return Err(ApprovalMismatch)
  }
  match check_authority(self.authorization_.unwrap(), (self.now_ms_)()) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  self.busy_ = true
  defer {
    self.busy_ = false
  }
  if approver.approve(preview) != Grant {
    self.phase_ = Rejected
    return Err(HostDenied)
  }
  let approval : ExpansionApproval = { preview_: preview, }
  self.approval_ = Some(approval)
  self.phase_ = Approved
  Ok(approval)
}

///|
/// Step 4: one backend expand_graph call, never a per-task command sequence.
/// Cancellation and unknown failures conservatively freeze the allocated IDs.
pub async fn ExpansionHost::commit(
  self : ExpansionHost,
  approval : ExpansionApproval,
) -> Result[Unit, ExpansionError] {
  if self.busy_ {
    return Err(Busy)
  }
  if self.phase_ != Approved {
    return Err(InvalidPhase)
  }
  if !physical_equal(self.approval_.unwrap(), approval) ||
    !physical_equal(approval.preview_, self.preview_.unwrap()) {
    return Err(ApprovalMismatch)
  }
  self.busy_ = true
  defer {
    self.busy_ = false
  }
  // No path may retry commit after starting this operation.
  self.phase_ = Conflict
  let draft = self.draft_.unwrap()
  let auth = self.authorization_.unwrap()
  let snapshot = match self.read_snapshot() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match
    validate_expansion(draft, snapshot, auth, self.policy_, (self.now_ms_)()) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let (expansions, tasks) = workflow_usage(snapshot, auth.workflow_)
  if expansions != approval.preview_.budgets.expansions_used ||
    tasks != approval.preview_.budgets.cumulative_tasks {
    return Err(StalePreview)
  }
  let ids = snapshot.tasks.map(t => t.id)
  let allocated : Array[@domain.BoardTaskId] = []
  for index, task in draft.tasks {
    let raw = self.allocator_.canonical_task_id(
      proposal_id=draft.proposal_id,
      key=task.key,
      index~,
    )
    let id = @domain.BoardTaskId(raw)
    if raw.is_empty() ||
      raw.length() > 128 ||
      raw
      .iter()
      .any(ch => ch.is_whitespace() || ch.to_int() < 32 || ch.to_int() == 127) ||
      ids.contains(id) ||
      allocated.contains(id) {
      return Err(AllocationFailed)
    }
    allocated.push(id)
    self.mapping_.push((task.key, id))
  }
  self.candidates_ = graph_candidates(draft, self.mapping_)
  let now = (self.now_ms_)()
  match check_authority(auth, now) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let checked = match
    @domain.BoardDomain::preview_expand_graph(
      snapshot,
      expansion=@domain.ExpansionId(draft.proposal_id),
      candidates=self.candidates_,
      parent=@domain.BoardTaskId(auth.parent_),
      workflow=auth.workflow_,
      at_ms=now,
      expected_revision=draft.base_revision,
    ).map_err(e => DomainRejected(e)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.expected_digest_ = Some(checked.digest)
  self.phase_ = CommitRequested
  defer (if self.phase_ == CommitRequested { self.phase_ = Uncertain })
  match
    self.backend_.expand_graph(
      expansion=@domain.ExpansionId(draft.proposal_id),
      candidates=self.candidates_,
      parent=@domain.BoardTaskId(auth.parent_),
      workflow=auth.workflow_,
      at_ms=Some(now),
      expected_revision=draft.base_revision,
    ) {
    Ok(_) => {
      self.phase_ = Committed
      Ok(())
    }
    Err(error) => {
      self.phase_ = match error {
        @coordinator.Rejected(_) => Conflict
        _ => Uncertain
      }
      Err(Backend(error))
    }
  }
}

///|
/// Read-only reconciliation. Absence is not permission to replay or reallocate.
pub async fn ExpansionHost::reconcile(
  self : ExpansionHost,
) -> Result[Bool, ExpansionError] {
  if self.busy_ {
    return Err(Busy)
  }
  if self.phase_ != Uncertain {
    return Err(InvalidPhase)
  }
  self.busy_ = true
  defer {
    self.busy_ = false
  }
  let record = match
    recover_expansion(self.backend_, self.draft_.unwrap().proposal_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match record {
    None => Ok(false)
    Some(record) => {
      if Some(record.content_digest) != self.expected_digest_ {
        self.phase_ = Conflict
        return Err(DigestConflict)
      }
      self.phase_ = Committed
      Ok(true)
    }
  }
}

///|
/// Always read a fresh authoritative snapshot and call the existing S4B planner.
pub async fn ExpansionHost::outlook(
  self : ExpansionHost,
) -> Result[Array[GeneratedTaskOutlook], ExpansionError] {
  if self.busy_ {
    return Err(Busy)
  }
  if self.phase_ != Committed {
    return Err(InvalidPhase)
  }
  let snapshot = match self.read_snapshot() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(
    expansion_execution_outlook(
      keys=self.mapping_.map(pair => pair.0),
      task_ids=self.mapping_.map(pair => pair.1.value),
      snapshot~,
      workflow_task_scope=self.authorization_.unwrap().workflow_scope_,
    ),
  )
}
