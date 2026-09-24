///|
// HerdrDelegate — the single high-level delegation tool. One call splits a
// visible herdr pane beside this one, launches cetas-headless there with the
// task, blocks until its completion marker (or timeout), reads the pane back
// and returns the headless answer. The child is a depth-1 leaf: hosts never
// wire delegation tools into headless, so it cannot delegate further. Tool
// semantics live here; the CLI transport is the HerdrCli seam supplied per
// target.

///|
pub struct HerdrDelegate {
  pane : String
  bin : String
  headless_bin : String
  cwd : String
  // In-flight delegate count; the single-threaded event loop makes the plain
  // counter safe under parallel tool waves (subagent ledger precedent).
  // Background delegations hold a slot for their whole async run.
  mut active : Int
  /// The Agent-owned task capability, captured at on_compose from the
  /// Capability::Tasks the manifest requires; None before composition.
  mut tasks : @posoco.Tasks?
  /// Parent session of the operation currently executing, tracked from
  /// scoped observer events — background results are addressed to it.
  mut session : String?
  /// Test seam: overrides the background runner's channel execution (the
  /// default runs the shared run_channel flow over the execute-time CLI).
  /// Slot management, the core timeout margin, and outcome projection stay
  /// in background_execute. Production leaves it None.
  priv background_run : (async (HerdrDelegate) -> @posoco.ToolOutcome)?
}

///|
pub fn HerdrDelegate::HerdrDelegate(
  pane~ : String,
  bin~ : String,
  headless_bin~ : String,
  cwd~ : String,
  background_run? : (async (HerdrDelegate) -> @posoco.ToolOutcome)? = None,
) -> HerdrDelegate {
  {
    pane,
    bin,
    headless_bin,
    cwd,
    active: 0,
    tasks: None,
    session: None,
    background_run,
  }
}

///|
let herdr_delegate_limit : Int = 4

///|
let herdr_default_timeout_ms : Int = 1800000

///|
/// Shared composition gate for targets with environment access: the
/// reporter's HERDR_ENV + HERDR_PANE_ID gate decides presence; the headless
/// binary defaults to "cetas-headless" when CETAS_HEADLESS_BIN is missing or
/// blank.
#cfg(any(target="native", target="wasm", target="js"))
fn herdr_delegate_gate(
  marker : String?,
  pane : String?,
  bin : String?,
  headless_bin : String?,
  cwd : String,
) -> HerdrDelegate? {
  match herdr_gate(marker, pane, bin) {
    Some(cfg) => {
      let headless = match headless_bin {
        Some(bin) if bin != "" => bin
        _ => "cetas-headless"
      }
      Some(
        HerdrDelegate::HerdrDelegate(
          pane=cfg.pane,
          bin=cfg.bin,
          headless_bin=headless,
          cwd~,
        ),
      )
    }
    None => None
  }
}

///|
fn herdr_delegate_tooldef() -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked("herdr_delegate"),
    description: "Delegate one task to a fresh cetas-headless agent in a visible herdr pane: splits a new pane beside this one, launches cetas-headless there with the task, blocks until its completion marker or the timeout, then reads the pane back and returns the headless agent's answer as the tool result. 'task' is the user-position slot — untrusted content may flow there, and it must be a single line. Delegated agents are depth-1 leaves: they never receive delegation tools, so they cannot delegate further. The result footer carries 'peer_pane:' (the child's herdr pane id) and, when captured, 'child_session:' (returned on success, failure, and best-effort timeout; pass it back via 'session' to continue that child). 'permission' controls the child: readonly (default) runs cetas-headless --permission readonly (it cannot write); write runs it with --yolo (unattended full permission). 'model'/'effort'/'session' forward to cetas-headless; 'timeout_ms' bounds the wait (default 1800000 = 30 minutes). 'direction' is the split direction (default right, or down); 'close_pane' (default true) closes the child pane after a successful run — it never closes on failure or timeout, since a timed-out child may still be running. Long-running: pass background: true to get an immediate receipt (delegation_id) and receive the child's result as a follow-up turn — background always starts a fresh child and refuses 'session', since a timed-out child may still be running in its pane and resume stays foreground-only. Strategy: batch independent subtasks as multiple herdr_delegate calls in one response — they run as parallel panes (concurrency cap 4); send a readonly scout first and reserve write for tasks that must modify the workspace; tell children to write long artifacts to workspace files, since pane readback can truncate, and iterate on a child by passing its child_session back via 'session' — related tasks MUST reuse the same child session (one work-stream = one child session, never a fresh session per step; child_session is returned even on failure and timeout). Omit 'session' for a new conversation — never pass an empty string; pass 'session' only to continue an existing child.",
    input_schema: Json::object({
      "type": Json::string("object"),
      "properties": Json::object({
        "task": Json::object({
          "type": Json::string("string"),
          "description": Json::string(
            "Single-line task for the delegated headless agent. User-position slot: untrusted content may flow here.",
          ),
        }),
        "permission": Json::object({
          "type": Json::string("string"),
          "enum": Json::array([Json::string("readonly"), Json::string("write")]),
          "default": Json::string("readonly"),
          "description": Json::string(
            "readonly (default) launches headless with --permission readonly (cannot write); write launches with --yolo (unattended full permission)",
          ),
        }),
        "model": Json::object({
          "type": Json::string("string"),
          "description": Json::string(
            "Optional model slot forwarded to cetas-headless --model",
          ),
        }),
        "effort": Json::object({
          "type": Json::string("string"),
          "description": Json::string(
            "Optional reasoning effort forwarded to cetas-headless --effort",
          ),
        }),
        "session": Json::object({
          "type": Json::string("string"),
          "description": Json::string(
            "Child session id from a previous result or error footer (returned on success, failure, and best-effort timeout); re-launches headless with --session to continue that child. Related or follow-up tasks MUST reuse the same child session instead of spawning a new one. Omit 'session' for a new conversation — never pass an empty string; pass 'session' only to continue an existing child (child_session from a prior result/error footer)",
          ),
        }),
        "timeout_ms": Json::object({
          "type": Json::string("integer"),
          "default": Json::number(1800000.0),
          "description": Json::string(
            "Wait bound for the completion marker in milliseconds (default 1800000 = 30 minutes)",
          ),
        }),
        "direction": Json::object({
          "type": Json::string("string"),
          "enum": Json::array([Json::string("right"), Json::string("down")]),
          "default": Json::string("right"),
          "description": Json::string("Direction of the split (default right)"),
        }),
        "close_pane": Json::object({
          "type": Json::string("boolean"),
          "default": Json::boolean(true),
          "description": Json::string(
            "Close the child pane after a successful run (default true); failures and timeouts leave the pane open",
          ),
        }),
        "background": Json::object({
          "type": Json::string("boolean"),
          "default": Json::boolean(false),
          "description": Json::string(
            "Return a receipt immediately and run the delegation in the background; the result arrives later as a follow-up turn. Background always starts a fresh child and cannot take 'session'.",
          ),
        }),
      }),
      "required": Json::array([Json::string("task")]),
    }),
    owner: @posoco.OwnerId::unchecked("placeholder"),
    policy: @posoco.ExecutionPolicy::Parallel,
    provenance: Some("posoco_ext_herdr"),
  }
}

///|
/// Declare the `herdr_delegate` tool.
pub fn HerdrDelegate::shared_list_tools() -> Array[@posoco.ToolDef] {
  [herdr_delegate_tooldef()]
}

///|
/// Pull just the task out first: the single-line check must run before any
/// other step, and a newline would let the task escape the one `pane run`
/// argv element into separate shell commands.
fn extract_delegate_task(args : Json) -> Result[String, String] {
  match args {
    Object(obj) =>
      match obj.get("task") {
        Some(String(task)) => Ok(task)
        _ =>
          Err(
            "herdr_delegate: missing or invalid 'task'; pass a non-empty single-line string",
          )
      }
    _ =>
      Err(
        "herdr_delegate: invalid arguments; pass a JSON object with a 'task' string",
      )
  }
}

///|
priv struct HerdrDelegateArgs {
  task : String
  permission : String
  model : String?
  effort : String?
  session : String?
  timeout_ms : Int
  direction : String
  close_pane : Bool
  background : Bool
}

///|
/// Extract the remaining tool-call arguments. Validation failures return a
/// model-visible fix hint; the caller turns them into a ToolReportedError.
fn extract_delegate_args(args : Json) -> Result[HerdrDelegateArgs, String] {
  let obj = match args {
    Object(obj) => obj
    _ => return Err("herdr_delegate: invalid arguments; expected a JSON object")
  }
  let task = match obj.get("task") {
    Some(String(s)) =>
      if s == "" {
        return Err(
          "herdr_delegate: 'task' must be a non-empty single-line string",
        )
      } else {
        s
      }
    _ => return Err("herdr_delegate: 'task' must be a string")
  }
  let permission = match obj.get("permission") {
    Some(String("readonly")) => "readonly"
    Some(String("write")) => "write"
    Some(String(other)) =>
      return Err(
        "herdr_delegate: 'permission' must be \"readonly\" or \"write\", got \"\{other}\"",
      )
    None | Some(Null) => "readonly"
    Some(_) => return Err("herdr_delegate: 'permission' must be a string")
  }
  // Empty strings normalize to None: an omitted flag means a new conversation
  // / default, and forwarding an empty value would break the command line.
  let model = match obj.get("model") {
    Some(String("")) => None
    Some(String(s)) => Some(s)
    None | Some(Null) => None
    Some(_) => return Err("herdr_delegate: 'model' must be a string")
  }
  let effort = match obj.get("effort") {
    Some(String("")) => None
    Some(String(s)) => Some(s)
    None | Some(Null) => None
    Some(_) => return Err("herdr_delegate: 'effort' must be a string")
  }
  let session = match obj.get("session") {
    Some(String("")) => None
    Some(String(s)) => Some(s)
    None | Some(Null) => None
    Some(_) =>
      return Err(
        "herdr_delegate: 'session' must be a string",
      )
  }
  let timeout_ms = match obj.get("timeout_ms") {
    Some(Number(value, ..)) =>
      if value > 0.0 {
        value.to_int()
      } else {
        return Err("herdr_delegate: 'timeout_ms' must be > 0")
      }
    None | Some(Null) => herdr_default_timeout_ms
    Some(_) => return Err("herdr_delegate: 'timeout_ms' must be an integer")
  }
  let direction = match obj.get("direction") {
    Some(String("right")) => "right"
    Some(String("down")) => "down"
    Some(String(other)) =>
      return Err(
        "herdr_delegate: 'direction' must be \"right\" or \"down\", got \"\{other}\"",
      )
    None | Some(Null) => "right"
    Some(_) => return Err("herdr_delegate: 'direction' must be a string")
  }
  let close_pane = match obj.get("close_pane") {
    Some(True) => true
    Some(False) => false
    None | Some(Null) => true
    Some(_) => return Err("herdr_delegate: 'close_pane' must be a boolean")
  }
  let background = match obj.get("background") {
    Some(True) => true
    Some(False) | None | Some(Null) => false
    Some(_) => return Err("herdr_delegate: 'background' must be a boolean")
  }
  if background && session is Some(_) {
    return Err(
      "herdr_delegate: background mode always starts a fresh child and cannot resume — omit 'session' for background; use a foreground call with 'session' to continue an existing child",
    )
  }
  Ok({
    task,
    permission,
    model,
    effort,
    session,
    timeout_ms,
    direction,
    close_pane,
    background,
  })
}

///|
fn herdr_delegate_error(content : String) -> @posoco.ToolOutcome {
  @posoco.ToolOutcome::ToolReportedError(content~, structured=None)
}

///|
/// The resumable-session line appended to success results and failure/timeout
/// errors alike: the headless session id prints before the turn, so even a
/// failed or timed-out run left a session the parent can resume.
fn herdr_child_session_line(child_session : String?) -> String {
  match child_session {
    Some(session) => "\nchild_session: \{session}"
    None => ""
  }
}

///|
/// Shared execute logic (target-agnostic): single-line task check first,
/// then the concurrency guard, then arg validation, then either the
/// background submit or the blocking channel flow. The in-flight counter is
/// decremented on every exit path (background: by the runner itself).
async fn HerdrDelegate::execute_delegate_impl(
  self : HerdrDelegate,
  cli : &HerdrCli,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  match extract_delegate_task(call.arguments) {
    Err(message) => return herdr_delegate_error(message)
    Ok(task) =>
      if task.contains("\n") {
        return herdr_delegate_error(
          "herdr_delegate: task must be a single line",
        )
      }
  }
  if self.active >= herdr_delegate_limit {
    return herdr_delegate_error(
      "herdr_delegate: delegate concurrency limit reached (\{herdr_delegate_limit} active) — retry when earlier delegates finish",
    )
  }
  let args = match extract_delegate_args(call.arguments) {
    Ok(args) => args
    Err(message) => return herdr_delegate_error(message)
  }
  if args.background {
    return self.background_execute(cli, args)
  }
  self.active += 1
  errdefer {
    self.active -= 1
  }
  let outcome = self.run_channel(cli, args)
  self.active -= 1
  outcome
}

///|
/// The channel flow: split a pane, launch headless, wait for the marker,
/// read the pane back, then (unless close_pane is false) close the pane.
/// Every CLI failure is a model-visible
/// ToolReportedError; only spawn/transport breakage raises.
async fn HerdrDelegate::run_channel(
  self : HerdrDelegate,
  cli : &HerdrCli,
  args : HerdrDelegateArgs,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let (split_exit, split_out, split_err) = cli.run(
    herdr_split_argv(self.bin, self.pane, self.cwd, args.direction),
  )
  if split_exit != 0 {
    return herdr_delegate_error(
      "herdr_delegate: pane split failed (exit \{split_exit}): \{herdr_excerpt(split_err)}",
    )
  }
  let new_pane = match parse_split_pane_id(split_out) {
    Some(id) => id
    None =>
      return herdr_delegate_error(
        "herdr_delegate: split output carried no pane id: \{herdr_excerpt(split_out)}",
      )
  }
  let command_line = headless_command_line(
    self.headless_bin,
    args.permission,
    args.model,
    args.effort,
    args.session,
    args.task,
  )
  let (run_exit, _run_out, run_err) = cli.run(
    herdr_run_argv(self.bin, new_pane, command_line),
  )
  if run_exit != 0 {
    return herdr_delegate_error(
      "herdr_delegate: launching headless in pane \{new_pane} failed (exit \{run_exit}): \{herdr_excerpt(run_err)}",
    )
  }
  let (wait_exit, _wait_out, wait_err) = cli.run(
    herdr_wait_argv(self.bin, new_pane, args.timeout_ms),
  )
  if wait_exit != 0 {
    if is_timeout_error(wait_exit, wait_err) {
      // Best-effort session capture on timeout: one extra read, never a
      // close (a timed-out child may still be running). A failed read is
      // silently omitted.
      let mut timeout_session : String? = None
      let (read_exit, timeout_read_out, _timeout_read_err) = cli.run(
        herdr_read_argv(self.bin, new_pane),
      )
      if read_exit == 0 {
        timeout_session = parse_pane_text(timeout_read_out).child_session
      }
      return herdr_delegate_error(
        "herdr_delegate: delegate timed out after \{args.timeout_ms} ms (peer_pane: \{new_pane}); the pane is left open and the child may still be running\{herdr_child_session_line(timeout_session)}",
      )
    }
    return herdr_delegate_error(
      "herdr_delegate: wait-output failed (exit \{wait_exit}): \{herdr_excerpt(wait_err)}",
    )
  }
  let (read_exit, read_out, read_err) = cli.run(
    herdr_read_argv(self.bin, new_pane),
  )
  if read_exit != 0 {
    return herdr_delegate_error(
      "herdr_delegate: pane read failed (exit \{read_exit}): \{herdr_excerpt(read_err)}",
    )
  }
  let pane = parse_pane_text(read_out)
  match pane.failure {
    Some(reason) =>
      return herdr_delegate_error(
        "[cetas-headless] turn failed: \{reason}\npeer_pane: \{new_pane}\{herdr_child_session_line(pane.child_session)}",
      )
    None => ()
  }
  // The child exited (the idle sentinel proved the pane is back at a prompt)
  // without printing any protocol line: pane.answer here is screen junk
  // holding the real death cause (usage text, env errors, ...).
  if !pane.done {
    return herdr_delegate_error(
      "herdr_delegate: child exited before printing a completion marker (peer_pane: \{new_pane}); pane excerpt: \{herdr_excerpt(pane.answer)}",
    )
  }
  // Close fires only here: after a successful read with no failure line.
  // A failed close is not fatal — the pane is still usable and inspectable.
  let mut footer = "peer_pane: \{new_pane}"
  footer = footer + herdr_child_session_line(pane.child_session)
  if args.close_pane {
    let (close_exit, _close_out, _close_err) = cli.run(
      herdr_close_argv(self.bin, new_pane),
    )
    if close_exit != 0 {
      footer = footer + "\nnote: pane auto-close failed (pane still open)"
    }
  }
  @posoco.ToolOutcome::Success(
    content="\{pane.answer}\n\n\{footer}",
    structured=None,
  )
}

///|
/// Background path: submit the delegation to the Agent-owned task capability
/// (captured at on_compose) and return the receipt immediately. The runner
/// executes the same channel flow inside the host agent's run_scoped scope;
/// core delivers its terminal outcome to the parent session as a follow-up
/// turn on the next ordinary run_turn. There is deliberately no extension-
/// side queue: an uncommitted outcome is retained and retried by core.
///
/// Concurrency: the shared guard in execute_delegate_impl already capped
/// admission; the in-flight slot is reserved here at accept and released by
/// the runner on every exit path — or immediately when the submit is refused.
fn HerdrDelegate::background_execute(
  self : HerdrDelegate,
  cli : &HerdrCli,
  args : HerdrDelegateArgs,
) -> @posoco.ToolOutcome {
  let tasks = match self.tasks {
    Some(tasks) => tasks
    None =>
      return herdr_delegate_error(
        "herdr_delegate: background mode requires the composed task capability — compose the manifest (requires Tasks) and run the host agent under Agent::run_scoped",
      )
  }
  let parent_session = match self.session {
    Some(session) => session
    None =>
      return herdr_delegate_error(
        "herdr_delegate: no parent session observed yet — background results are addressed to the session whose run invoked this tool",
      )
  }
  let channel_run : async (HerdrDelegate) -> @posoco.ToolOutcome = match
    self.background_run {
    Some(override_run) => override_run
    None => async fn(d : HerdrDelegate) { d.run_channel(cli, args) }
  }
  self.active += 1
  // Core's task timeout is a last-resort cancellation net only: the channel
  // flow enforces its own graceful protocol timeout first (`pane wait-output`
  // bounded by args.timeout_ms leaves the pane open and best-effort captures
  // child_session — a delivered result the model must read), so the +5000 ms
  // margin lets the graceful path always win the race.
  let accepted = tasks.submit({
    session_id: parent_session,
    mode: @posoco.TaskMode::Background,
    label: "herdr_delegate",
    timeout_ms: Some(args.timeout_ms + 5000),
    run: self.background_task_run(channel_run),
  })
  match accepted {
    Ok(handle) => {
      let receipt = handle.receipt()
      @posoco.ToolOutcome::Success(
        content="background herdr_delegate accepted\ndelegation_id: \{receipt.id}\na fresh pane and child session will start; the result arrives as a follow-up turn",
        structured=Some(
          Json::object(
            Map::from_array([
              ("background", Json::boolean(true)),
              ("delegation_id", Json::string(receipt.id)),
            ]),
          ),
        ),
      )
    }
    Err(error) => {
      self.active -= 1
      match error {
        @posoco.TaskSubmitError::Unavailable =>
          herdr_delegate_error(
            "herdr_delegate: background submit unavailable — the host agent is not running under Agent::run_scoped",
          )
        @posoco.TaskSubmitError::Closed =>
          herdr_delegate_error(
            "herdr_delegate: background submit refused — the agent is shut down",
          )
        @posoco.TaskSubmitError::QueueFull =>
          herdr_delegate_error(
            "herdr_delegate: background queue full — retry shortly",
          )
        @posoco.TaskSubmitError::InvalidSession(reason~) =>
          herdr_delegate_error(
            "herdr_delegate: background submit refused (invalid session): \{reason}",
          )
      }
    }
  }
}

///|
/// The TaskSpec.run closure: execute the channel flow, guard cancellation on
/// both exit paths, release the in-flight slot, and project the outcome to
/// the message core delivers to the parent session. A failed or timed-out
/// delegation is still a RESULT the model must read (the child_session
/// footer matters for follow-up), so both content-carrying outcomes project
/// to text; only transport breakage re-raises, which core maps to
/// Failed(reason).
///
/// Cancellation guard (both paths): a cancelled coroutine stays cancelled —
/// pause() re-raises the genuine cancellation (a suberror that flows through
/// any typed error channel) so the task group records cancelled rather than
/// failed/completed, and the timer's TimeoutError wins over adapter error
/// masking. Without a pending cancellation the pause is a no-op yield.
#warnings("-fragile_catch_all")
fn HerdrDelegate::background_task_run(
  self : HerdrDelegate,
  channel_run : async (HerdrDelegate) -> @posoco.ToolOutcome,
) -> async () -> @posoco.Message {
  async fn() {
    // The slot is released exactly once on EVERY exit: errdefer owns every
    // raise-exit (including the cancellation guards below), the explicit
    // decrement owns the normal return.
    errdefer {
      self.active -= 1
    }
    let outcome = channel_run(self) catch {
      error => {
        @async.pause()
        raise error
      }
    }
    @async.pause()
    self.active -= 1
    let text = match outcome {
      @posoco.ToolOutcome::Success(content~, ..) => content
      @posoco.ToolOutcome::ToolReportedError(content~, ..) => content
      other => other.summary()
    }
    @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)])
  }
}

///|
/// Resident host strategy. ToolDef covers call mechanics; this contributor
/// keeps cross-call delegation policy visible for the whole session.
pub impl @posoco.SystemPromptContributor for HerdrDelegate with fn system_prompt(
  self : HerdrDelegate,
) -> String {
  (
    "Herdr pane \{self.pane}: `herdr_delegate` runs visible depth-1 cetas-headless children; children cannot delegate.\n" +
    "- Use it for independent parallelizable subtasks, process isolation, or long work; multiple calls in one response run in parallel (cap 4).\n" +
    "- Prefer permission=readonly for reconnaissance. write uses --yolo; use it only when the child must modify the workspace.\n" +
    "- Pane readback can truncate; have children write important/long artifacts to workspace files.\n" +
    "- Related/follow-up work MUST reuse the returned child_session, including after failure/timeout. One work-stream = one child session. Omit session only for a new conversation; never pass an empty session."
  )
}

///|
/// A HerdrDelegate contributes its tool and declares the Agent-owned task
/// capability it consumes for background delegations and its resident
/// strategy prompt: the same value is a Lifecycle
/// contributor (captures the composed Tasks at on_compose) and an Observer
/// (tracks the parent session from scoped events). No hooks: core's session
/// inbox owns background-result delivery.
pub impl @posoco.Extension for HerdrDelegate with fn manifest(
  self : HerdrDelegate,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="posoco_ext_herdr_delegate",
    tools=[self],
    observers=[self as &@posoco.Observer],
    lifecycle=[self as &@posoco.Lifecycle],
    prompt_contributors=[self],
    requires=[@posoco.Capability::Tasks],
  )
}

///|
/// Composition: capture the Agent-owned task capability delivered because the
/// manifest requires Capability::Tasks. Submitting before run_scoped is
/// refused at the tool layer with an explicit model-visible error.
pub impl @posoco.Lifecycle for HerdrDelegate with fn on_compose(
  self : HerdrDelegate,
  view : @posoco.CompositionView,
) {
  self.tasks = view.tasks()
}

///|
pub extend HerdrDelegate with @posoco.Lifecycle::{
  on_compose,
  on_shutdown,
  on_start,
}

///|
/// The delegate owns no lifecycle resources: child panes belong to the child,
/// and core owns background-task cleanup — shutdown stays a no-op.
pub impl @posoco.Lifecycle for HerdrDelegate with fn on_shutdown(
  _self : HerdrDelegate,
) -> Unit {
  ()
}

///|
pub impl @posoco.Observer for HerdrDelegate with fn on_event(
  _self : HerdrDelegate,
  _event : @posoco.TurnEvent,
) -> Unit {
  ()
}

///|
pub extend HerdrDelegate with @posoco.Observer::{on_event, on_event_at}

///|
/// Track the parent session from scoped events; a background delegation
/// addresses its TaskSpec to this session so core delivers the outcome there.
pub impl @posoco.Observer for HerdrDelegate with fn on_event_at(
  self : HerdrDelegate,
  scope : @posoco.EventScope?,
  _event : @posoco.TurnEvent,
) -> Unit {
  match scope {
    Some(s) => self.session = Some(s.session_id.to_string())
    None => ()
  }
}
