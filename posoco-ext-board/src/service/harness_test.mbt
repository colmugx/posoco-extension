///|
struct ScriptedUi {
  mut grant : Bool
  prompts : Array[String]
  mut before_answer : (() -> Unit)?
}

///|
impl @posoco.Extension for ScriptedUi with fn extension_id(_) {
  "test-workflow-ui"
}

///|
impl @posoco.Extension for ScriptedUi with fn manifest(self) {
  @posoco.ExtensionManifest(id="test-workflow-ui", ui=[self])
}

///|
impl @posoco.UiPort for ScriptedUi with fn ui_descriptor(_) {
  @posoco.UiDescriptor::empty()
}

///|
impl @posoco.UiPort for ScriptedUi with fn render(_, _) {
  ()
}

///|
impl @posoco.UiPort for ScriptedUi with fn request(self, request) {
  match request {
    @posoco.UiRequest::Confirm(prompt~) => {
      self.prompts.push(prompt)
      if self.before_answer is Some(hook) {
        hook()
      }
      if self.grant {
        @posoco.UiResponse::Yes
      } else {
        @posoco.UiResponse::No
      }
    }
    _ => @posoco.UiResponse::Cancelled
  }
}

///|
struct ScriptState {
  mut invalid : Bool
  mut fail : Bool
  mut delay : Int32
  mut chain : Bool
  mut active : Int32
  mut peak : Int32
  contexts : Array[@service.WorkflowAgentContext]
}

///|
struct ScriptModel {
  directory : String
  context : @service.WorkflowAgentContext
  state : ScriptState
}

///|
impl @posoco.Extension for ScriptModel with fn extension_id(_) {
  "controlled-model"
}

///|
impl @posoco.Extension for ScriptModel with fn manifest(self) {
  @posoco.ExtensionManifest(id="controlled-model", models=[self])
}

///|
impl @posoco.ModelPort for ScriptModel with fn provider_config(_) {
  @posoco.ProviderConfig::empty()
}

///|
impl @posoco.ModelPort for ScriptModel with fn chat(self, _, messages, _, _, _) {
  self.state.active += 1
  self.state.peak = self.state.peak.max(self.state.active)
  defer {
    self.state.active -= 1
  }
  if self.state.delay == -1 &&
    self.context.purpose == @service.WorkflowAgentPurpose::Execution {
    // Test-only barrier: both independent Agents must enter the model port.
    // A serialized runner fails the bounded wait instead of hanging.
    let joined = @async.with_timeout(2000, () => {
      while self.state.active < 2 {
        @async.sleep(1)
      }
      true
    }) catch {
      _ => false
    }
    if !joined {
      raise @posoco.ModelError::Transport("parallel test barrier timed out")
    }
  }
  if self.state.delay > 0 {
    @async.sleep(self.state.delay)
  }
  if self.state.fail {
    raise @posoco.ModelError::Transport("private-provider-secret-must-not-leak")
  }
  let payload = if self.context.purpose ==
    @service.WorkflowAgentPurpose::Planning {
    if self.state.invalid {
      "invalid private raw model output"
    } else {
      let loaded = @store.FileBoardStore::at_directory(directory=self.directory).load() catch {
        _ => raise @posoco.ModelError::Transport("test storage failed")
      }
      let revision = match loaded {
        Ok(loaded) => loaded.snapshot.revision + 1L
        Err(_) =>
          raise @posoco.ModelError::Transport("test storage unavailable")
      }
      let a : Json = {
        "key": "a",
        "title": "Research",
        "description": "Untrusted generated task description",
        "priority": "normal",
        "definition_of_done": ["Evidence checked"],
        "depends_on": [],
      }
      let b : Json = {
        "key": "b",
        "title": "Implement",
        "description": "Implementation",
        "priority": "normal",
        "definition_of_done": [],
        "depends_on": (
          if self.state.chain {
            [{ "local": "a" }]
          } else {
            []
          } : Json),
      }
      let result : Json = {
        "schema_version": 1,
        "proposal_id": "proposal-" + self.context.attempt_id,
        "parent_task_id": self.context.task_id,
        "base_revision": Json::number(revision.to_double()),
        "tasks": Json::array([a, b]),
      }
      result.stringify()
    }
  } else {
    "private actual Agent execution result"
  }
  {
    completion: @kernel.Completion(
      content=[@kernel.Text(payload)],
      tool_calls=[],
      reasoning=None,
      finish_reason=Stop,
      usage=None,
    ),
    processed_messages: messages.to_owned(),
  }
}

///|
impl @posoco.ModelPort for ScriptModel with fn compact(_, _, _, _, _, _) {
  raise @posoco.ModelError::Transport("unexpected compact")
}

///|
struct ScriptFactory {
  directory : String
  state : ScriptState
}

///|
impl @service.WorkflowAgentFactory for ScriptFactory with fn prepare(
  self,
  context,
) {
  self.state.contexts.push(context)
  @async.pause()
  {
    extensions: [
      ScriptModel::{ directory: self.directory, context, state: self.state, },
    ],
    config: @posoco.agent_config(max_tool_rounds=Some(0)),
  }
}

///|
struct Harness {
  board : @service.BoardWorkflows
  ui : ScriptedUi
  state : ScriptState
  parent : @posoco.Agent
}

///|
fn harness(
  directory : String,
  group : @async.TaskGroup[Unit],
  enabled~ : Bool = true,
  max_executions~ : Int32 = 8,
  continue_on_confirmed_failure~ : Bool = false,
  authorize~ : () -> Bool = () => true,
  policy~ : @service.BoardWorkflowPolicy? = None,
) -> Harness raise {
  let state = ScriptState::{
    invalid: false,
    fail: false,
    delay: 1,
    chain: true,
    active: 0,
    peak: 0,
    contexts: [],
  }
  let ui = ScriptedUi::{ grant: true, prompts: [], before_answer: None, }
  let board = @service.BoardWorkflows(
    directory~,
    group~,
    agents=ScriptFactory::{ directory, state, },
    policy=policy.unwrap_or(
      @service.BoardWorkflowPolicy(
        enabled~,
        max_executions~,
        continue_on_confirmed_failure~,
        execution_timeout_ms=10000,
        max_elapsed_ms=10000,
      ),
    ),
    now_ms=() => 100L,
    authorize~,
  )
  let parent_model = ScriptModel::{
    directory,
    state,
    context: {
      purpose: @service.WorkflowAgentPurpose::Execution,
      workflow_id: "parent",
      task_id: "parent",
      attempt_id: "parent",
      session_id: "parent",
      slot: 0,
    },
  }
  let parent = @posoco.Agent(
    exts=[parent_model, ui, board],
    config=@posoco.agent_config(),
  )
  { board, ui, state, parent, }
}

///|
async fn proposed(h : Harness) -> @service.BoardWorkflowView {
  let initial = h.board.start(title="Coding request").checked()
  let root = initial.run.checked().scope[0]
  ignore(
    h.board
    .propose(parent=root, requirements="trusted user coding requirements")
    .checked(),
  )
  h.board.graph_decision(grant=true).checked()
}
