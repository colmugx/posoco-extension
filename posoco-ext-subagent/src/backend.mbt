///|
/// Argument failures surface as tool-reported errors the calling model can
/// read and fix; they never raise through the provider boundary.
priv suberror SpawnArgError {
  Invalid(String)
}

///|
/// Parsed and type-validated `agent` arguments. `skills` is already mapped:
/// absent/false → `None`, true → `Some([])` (load all), array → whitelist.
priv struct SpawnArgs {
  task : String
  kind : String
  model : String?
  effort : String?
  tools : Array[String]?
  skills : Array[String]?
  instructions : String?
  context_files : Bool
  resume_id : String?
  timeout_ms : Int?
  background : Bool
}

///|
fn opt_string(
  fields : Map[String, Json],
  key : String,
) -> String? raise SpawnArgError {
  match fields.get(key) {
    None => None
    Some(Json::String(value)) => Some(value)
    Some(_) => raise SpawnArgError::Invalid("agent: '\{key}' must be a string")
  }
}

///|
fn opt_string_array(
  fields : Map[String, Json],
  key : String,
) -> Array[String]? raise SpawnArgError {
  match fields.get(key) {
    None => None
    Some(Json::Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          Json::String(value) => out.push(value)
          _ =>
            raise SpawnArgError::Invalid(
              "agent: '\{key}' entries must be strings",
            )
        }
      }
      Some(out)
    }
    Some(_) =>
      raise SpawnArgError::Invalid(
        "agent: '\{key}' must be an array of strings",
      )
  }
}

///|
fn opt_bool(
  fields : Map[String, Json],
  key : String,
) -> Bool? raise SpawnArgError {
  match fields.get(key) {
    None => None
    Some(Json::True) => Some(true)
    Some(Json::False) => Some(false)
    Some(_) => raise SpawnArgError::Invalid("agent: '\{key}' must be a boolean")
  }
}

///|
fn opt_int(
  fields : Map[String, Json],
  key : String,
) -> Int? raise SpawnArgError {
  match fields.get(key) {
    None => None
    Some(Json::Number(value, ..)) => {
      let whole = value.to_int()
      if value != whole.to_double() {
        raise SpawnArgError::Invalid("agent: '\{key}' must be an integer")
      }
      Some(whole)
    }
    Some(_) =>
      raise SpawnArgError::Invalid("agent: '\{key}' must be an integer")
  }
}

///|
fn parse_spawn_args(arguments : Json) -> SpawnArgs raise SpawnArgError {
  let fields = match arguments {
    Json::Object(fields) => fields
    _ => raise SpawnArgError::Invalid("agent: arguments must be a JSON object")
  }
  let task = match fields.get("task") {
    Some(Json::String(value)) =>
      if value.trim().is_empty() {
        raise SpawnArgError::Invalid("agent: 'task' must be a non-empty string")
      } else {
        value
      }
    Some(_) => raise SpawnArgError::Invalid("agent: 'task' must be a string")
    None =>
      raise SpawnArgError::Invalid("agent: missing required 'task' argument")
  }
  let skills : Array[String]? = match fields.get("skills") {
    None => None
    Some(Json::False) => None
    Some(Json::True) => Some([])
    Some(Json::Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          Json::String(value) => out.push(value)
          _ =>
            raise SpawnArgError::Invalid(
              "agent: 'skills' entries must be strings",
            )
        }
      }
      Some(out)
    }
    Some(_) =>
      raise SpawnArgError::Invalid(
        "agent: 'skills' must be a boolean or an array of strings",
      )
  }
  let timeout_ms = opt_int(fields, "timeout_ms")
  match timeout_ms {
    Some(ms) =>
      if ms <= 0 {
        raise SpawnArgError::Invalid(
          "agent: 'timeout_ms' must be a positive integer",
        )
      }
    None => ()
  }
  {
    task,
    kind: match opt_string(fields, "kind") {
      Some(value) => value
      None => "coder"
    },
    model: opt_string(fields, "model"),
    effort: opt_string(fields, "effort"),
    tools: opt_string_array(fields, "tools"),
    skills,
    instructions: opt_string(fields, "instructions"),
    context_files: match opt_bool(fields, "context_files") {
      Some(value) => value
      None => false
    },
    resume_id: opt_string(fields, "resume"),
    timeout_ms,
    background: match opt_bool(fields, "background") {
      Some(value) => value
      None => false
    },
  }
}

///|
fn list_contains(items : Array[String], value : String) -> Bool {
  for item in items {
    if item == value {
      return true
    }
  }
  false
}

///|
/// Text projection of the child's final assistant message: concatenated
/// `Text` blocks, other block kinds ignored, non-assistant messages project
/// to the empty string.
fn assistant_text(message : @posoco.Message) -> String {
  match message {
    @posoco.Message::AssistantMessage(content~, ..) => {
      let parts : Array[String] = []
      for block in content {
        match block {
          @posoco.Content::Text(text) => parts.push(text)
          @posoco.Content::Image(..) => ()
        }
      }
      parts.join("\n")
    }
    _ => ""
  }
}

///|
/// Uniform call shape for the kit's optional-`instructions` parameter.
fn assemble_prompt(
  kind_spec : @kind.KindSpec,
  instructions : String?,
) -> String raise @kit.PromptAssemblyError {
  match instructions {
    Some(text) => @kit.assemble_system_prompt(kind_spec, instructions=text)
    None => @kit.assemble_system_prompt(kind_spec)
  }
}

///|
fn terminal_for(
  bridge : BridgeObserver,
  spec : ChildSpec,
  state : @kit.TerminalState,
  result_text : String,
) -> @posoco.ToolOutcome {
  @kit.terminal_outcome(
    state~,
    kind=spec.kind_name,
    child_session=spec.session_id,
    result_text~,
    turns=bridge.turns,
    input_tokens=bridge.input_tokens,
    output_tokens=bridge.output_tokens,
  )
}

///|
/// Text projection of a terminal outcome (the content the tool result
/// carries); non-content variants project to the empty string.
fn outcome_text(outcome : @posoco.ToolOutcome) -> String {
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) => content
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => content
    _ => ""
  }
}

///|
/// Terminal mapping + registry bookkeeping shared by both paths: build the
/// tool outcome through the kit formatter and record the final state word /
/// summary text under the child's id (the resume key set).
fn SubagentTools::finish(
  self : SubagentTools,
  bridge : BridgeObserver,
  spec : ChildSpec,
  state : @kit.TerminalState,
  result_text : String,
) -> @posoco.ToolOutcome {
  let outcome = terminal_for(bridge, spec, state, result_text)
  let text = outcome_text(outcome)
  match self.registry.get(spec.session_id) {
    Some(record) => record.state = Done(@kit.terminal_state_word(state), text)
    None => ()
  }
  outcome
}

///|
/// Run one spawn (design §2.1, §3.2, §5): parse args, refuse background
/// calls that lack the composed task capability or a known parent session
/// before the budget gate (a refused call consumes no budget slot), validate
/// `resume` against the child registry, then the budget gate, argument
/// slicing, child composition through the injected port, and either the
/// background receipt (the child runs as an Agent-owned background task; its
/// terminal arrives as a follow-up turn in the parent session) or a single
/// blocking run under the timeout with the explicit terminal-state mapping.
/// Multiple `agent` calls in one model response ride the kernel's parallel
/// tool waves. The per-run ledger bounds total admissions; `global_slots`
/// bounds simultaneously live children across foreground and background work.
///
/// The child-run catch inspects the error to classify the terminal state, so
/// the fragile-catch-all lint is suppressed (same precedent as core's
/// `AgentRuntime::run_single_turn`).
#warnings("-fragile_catch_all")
async fn SubagentTools::spawn(
  self : SubagentTools,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome {
  let args = parse_spawn_args(call.arguments) catch {
    SpawnArgError::Invalid(message) =>
      return @posoco.ToolOutcome::ToolReportedError(
        content=message,
        structured=None,
      )
  }
  // Background refusals precede the budget gate (keep no-burn): the composed
  // capability and the known parent session are host-wiring gaps, not budget
  // conditions (design §5). The values bind here for the submit below.
  let mut capability : @posoco.Tasks? = None
  let mut parent_session : String? = None
  if args.background {
    match self.tasks {
      Some(tasks) => capability = Some(tasks)
      None =>
        return @posoco.ToolOutcome::ToolReportedError(
          content="background mode requires the composed task capability — compose the agent with the posoco_ext_subagent manifest (requires Tasks) and run the host under Agent::run_scoped",
          structured=None,
        )
    }
    match self.session {
      Some(session) => parent_session = Some(session)
      None =>
        return @posoco.ToolOutcome::ToolReportedError(
          content="background mode requires a known parent session — no scoped turn event has been observed yet, so the child's result would have nowhere to be delivered",
          structured=None,
        )
    }
  }
  // Resume validation (design §5): a `resume` id must be a child this tool
  // spawned; the ids are exactly what the tool-result footer advertises.
  // Checked before the budget gate: a mistyped id consumes nothing.
  match args.resume_id {
    Some(id) =>
      if !self.registry.contains(id) {
        let known : Array[String] = []
        for known_id, _record in self.registry {
          known.push(known_id)
        }
        let known_list = if known.is_empty() {
          "(none spawned yet)"
        } else {
          known.join(", ")
        }
        return @posoco.ToolOutcome::ToolReportedError(
          content="unknown resume id '\{id}' — known child sessions: \{known_list}",
          structured=None,
        )
      }
    None => ()
  }
  // Budget (design §6.3): explicit refusal, never a silent queue.
  if !self.ledger.try_acquire("agent") {
    return @posoco.ToolOutcome::ToolReportedError(
      content="spawn budget exhausted (\{self.ledger.acquired().length()}/\{self.config.limits.spawn_budget} used): explicit refusal — finish with the subagents you have",
      structured=None,
    )
  }
  let kind_spec = match self.catalog.get(args.kind) {
    Some(spec) => spec
    None =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="unknown kind '\{args.kind}' (available kinds: \{self.catalog.names().join(", ")}) — pick one of the listed kinds",
        structured=None,
      )
  }
  // Tool face: spawn whitelist ∩ kind whitelist, one layer, no propagation
  // along any chain (design §6.2). Absent argument = the kind's own face.
  let tools = match args.tools {
    None => kind_spec.tools.copy()
    Some(requested) => {
      let intersection : Array[String] = []
      let seen : Set[String] = Set([])
      for tool in requested {
        if !seen.contains(tool) && list_contains(kind_spec.tools, tool) {
          seen.add(tool)
          intersection.push(tool)
        }
      }
      if intersection.is_empty() {
        return @posoco.ToolOutcome::ToolReportedError(
          content="tool whitelist is empty after intersection: requested [\{requested.join(", ")}] ∩ kind '\{kind_spec.name}' [\{kind_spec.tools.join(", ")}] — request at least one tool from the kind's whitelist",
          structured=None,
        )
      }
      intersection
    }
  }
  let system_prompt = assemble_prompt(kind_spec, args.instructions) catch {
    @kit.PromptAssemblyError::InstructionsTooLong(message) =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="agent: \{message}",
        structured=None,
      )
  }
  let selection = self.config.resolve(
    model=args.model,
    effort=args.effort,
    parent_slot=self.parent_slot,
    parent_effort=self.parent_effort,
  ) catch {
    @kit.SubagentConfigError::Invalid(message) =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="agent: \{message}",
        structured=None,
      )
    @kit.SubagentConfigError::Malformed(message) =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="agent: \{message}",
        structured=None,
      )
  }
  let (session_id, resumed) = match args.resume_id {
    Some(id) => (id, true)
    None => {
      self.counter = self.counter + 1
      ("subagent-\{self.counter}", false)
    }
  }
  let timeout_ms = match args.timeout_ms {
    Some(ms) => ms
    None => self.config.limits.timeout_ms
  }
  let bridge = BridgeObserver::BridgeObserver(
    child_session=session_id,
    kind=kind_spec.name,
    callbacks=self.observers,
  )
  let spec : ChildSpec = {
    task: args.task,
    kind_name: kind_spec.name,
    session_id,
    resuming: resumed,
    tools,
    skills: args.skills,
    mode: kind_spec.mode,
    system_prompt,
    slot: selection.slot,
    effort: selection.effort,
    context_files: args.context_files,
    observers: [bridge as &@posoco.Observer],
  }
  // The configured global cap is a lifetime semaphore, not a refusal gate:
  // excess parallel calls wait FIFO and still consume only their one spawn
  // budget unit. Once acquired, the slot belongs to this child until its
  // foreground run returns or its Agent-owned background task actually exits.
  self.global_slots.acquire()
  errdefer {
    self.global_slots.release()
  }
  let child = self.composer.compose(spec) catch {
    ComposerError::Failed(reason) => {
      self.global_slots.release()
      return terminal_for(
        bridge,
        spec,
        @kit.TerminalState::Failed(reason~),
        "",
      )
    }
  }
  // Registered at spawn (design §5): both paths advertise the id in their
  // result footer, and `resume` accepts exactly these ids.
  self.registry[spec.session_id] = BackgroundRecord::BackgroundRecord(
    kind=spec.kind_name,
  )
  if args.background {
    // The precondition gate above bound both values; this is unreachable.
    let tasks = match capability {
      Some(tasks) => tasks
      None => abort("background capability was validated at the gate")
    }
    let session_id_target = match parent_session {
      Some(session) => session
      None => abort("background parent session was validated at the gate")
    }
    let user_message : @posoco.Message = @posoco.Message::UserMessage(content=[
      @posoco.Content::Text(spec.task),
    ])
    // Background runner (ruling 4): the child owns its lifetime through its
    // own run_scoped; the runner does no registry or event bookkeeping —
    // cancellation mid-run cannot guarantee it. Timeout and cancellation
    // belong to core (TaskSpec.timeout_ms).
    let runner : async () -> @posoco.Message = async fn() {
      // Ownership of the acquired global slot transfers to the background
      // task after submit succeeds. Release exactly once on every task exit.
      errdefer {
        self.global_slots.release()
      }
      let result : @posoco.TurnResult = child.run_scoped(async fn(agent) {
        if spec.resuming {
          agent.resume_turn(spec.session_id)
        } else {
          agent.run_turn(user_message, spec.session_id)
        }
      }) catch {
        error => {
          // A cancelled coroutine stays cancelled: pause() re-raises the
          // genuine cancellation (a suberror that flows through any typed
          // error channel) so the task group records this task as cancelled
          // rather than failed, and core's timeout classification survives
          // the child adapter's error masking. Without a cancellation the
          // pause is a no-op yield and the original error propagates.
          @async.pause()
          raise error
        }
      }
      // The after-return pause converts a cancellation the child adapter
      // swallowed into a returned value back into a real cancellation;
      // without a pending cancellation it is a no-op yield.
      @async.pause()
      self.global_slots.release()
      result.message
    }
    match
      tasks.submit({
        session_id: session_id_target,
        mode: @posoco.TaskMode::Background,
        label: spec.session_id,
        timeout_ms: Some(timeout_ms),
        run: runner,
      }) {
      Ok(handle) => {
        let receipt = handle.receipt()
        self.unobserved[receipt.id] = spec.session_id
        self.emit_custom(
          spec.session_id,
          spec.kind_name,
          "background_spawned",
          Json::object({
            "child_session": Json::string(spec.session_id),
            "kind": Json::string(spec.kind_name),
            "task_id": Json::string(receipt.id),
          }),
        )
        let structured : Json = {
          "background": Json::boolean(true),
          "child_session": Json::string(spec.session_id),
          "kind": Json::string(spec.kind_name),
          "task_id": Json::string(receipt.id),
        }
        return @posoco.ToolOutcome::Success(
          content="background subagent accepted\nchild_session: \{spec.session_id}\nkind: \{spec.kind_name}\ntask_id: \{receipt.id}\nresult will arrive as a follow-up turn",
          structured=Some(structured),
        )
      }
      Err(error) => {
        self.global_slots.release()
        let reason = match error {
          @posoco.TaskSubmitError::Unavailable =>
            "the task scope is not active — run the host under Agent::run_scoped"
          @posoco.TaskSubmitError::Closed => "the agent has been shut down"
          @posoco.TaskSubmitError::QueueFull =>
            "the task queue is full — retry later"
          @posoco.TaskSubmitError::InvalidSession(reason~) => reason
        }
        return @posoco.ToolOutcome::ToolReportedError(
          content="background subagent refused: \{reason}",
          structured=None,
        )
      }
    }
  }
  let user_message : @posoco.Message = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text(args.task),
  ])
  // Timeout wraps the child run (design §3.2). The `timed_out` flag — not
  // the unwinding error — decides the terminal classification: real model
  // adapters wrap cancellation into typed transport errors, so a child dying
  // mid-cancel must not masquerade as a business failure. Wave cancellation
  // (no timer involvement, cancellation-typed error) stays `Cancelled`;
  // aborts surface as their own classification.
  let mut timed_out = false
  let mut death : Error? = None
  let outcome : @posoco.TurnResult? = @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      @async.sleep(timeout_ms)
      timed_out = true
      group.return_immediately(None)
    })
    let result = child.run_turn(user_message, spec.session_id) catch {
      error => {
        death = Some(error)
        raise error
      }
    }
    Some(result)
  }) catch {
    _ => None
  }
  match outcome {
    Some(result) => {
      self.global_slots.release()
      return self.finish(
        bridge,
        spec,
        @kit.TerminalState::Completed,
        assistant_text(result.message),
      )
    }
    None => ()
  }
  let state = if timed_out {
    @kit.TerminalState::TimedOut
  } else {
    match death {
      Some(error) =>
        match error {
          @posoco.AgentError::PipelineAborted(_) =>
            @kit.TerminalState::Cancelled
          other => @kit.TerminalState::Failed(reason=other.to_string())
        }
      None => @kit.TerminalState::Cancelled
    }
  }
  self.global_slots.release()
  self.finish(bridge, spec, state, "")
}

///|
pub impl @posoco.ToolProvider for SubagentTools with fn execute(
  self : SubagentTools,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  if name != "agent" {
    raise @posoco.RuntimeError::UnknownTool(
      "posoco_ext_subagent: unknown tool '\{name}'",
    )
  }
  self.spawn(call) catch {
    error =>
      raise @posoco.RuntimeError::InvocationFailed(
        "agent tool: \{error.to_string()}",
      )
  }
}
