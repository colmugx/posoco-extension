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
  mut active : Int
}

///|
pub fn HerdrDelegate::HerdrDelegate(
  pane~ : String,
  bin~ : String,
  headless_bin~ : String,
  cwd~ : String,
) -> HerdrDelegate {
  { pane, bin, headless_bin, cwd, active: 0, }
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
#cfg(any(target="native", target="js"))
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
    description: "Delegate one task to a fresh cetas-headless agent in a visible herdr pane: splits a new pane beside this one, launches cetas-headless there with the task, blocks until its completion marker or the timeout, then reads the pane back and returns the headless agent's answer as the tool result. 'task' is the user-position slot — untrusted content may flow there, and it must be a single line. Delegated agents are depth-1 leaves: they never receive delegation tools, so they cannot delegate further. The result footer carries 'peer_pane:' (the child's herdr pane id) and, when captured, 'child_session:' (returned on success, failure, and best-effort timeout; pass it back via 'session' to continue that child). 'permission' controls the child: readonly (default) runs cetas-headless --permission readonly (it cannot write); write runs it with --yolo (unattended full permission). 'model'/'effort'/'session' forward to cetas-headless; 'timeout_ms' bounds the wait (default 1800000 = 30 minutes). 'direction' is the split direction (default right, or down); 'close_pane' (default true) closes the child pane after a successful run — it never closes on failure or timeout, since a timed-out child may still be running. Strategy: batch independent subtasks as multiple herdr_delegate calls in one response — they run as parallel panes (concurrency cap 4); send a readonly scout first and reserve write for tasks that must modify the workspace; tell children to write long artifacts to workspace files, since pane readback can truncate, and iterate on a child by passing its child_session back via 'session' — related tasks MUST reuse the same child session (one work-stream = one child session, never a fresh session per step; child_session is returned even on failure and timeout).",
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
            "Child session id from a previous result or error footer (returned on success, failure, and best-effort timeout); re-launches headless with --session to continue that child. Related or follow-up tasks MUST reuse the same child session instead of spawning a new one",
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
    _ => return Err("herdr_delegate: 'task' must be a non-empty string")
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
  let model = match obj.get("model") {
    Some(String(s)) => Some(s)
    None | Some(Null) => None
    Some(_) => return Err("herdr_delegate: optional 'model' must be a string")
  }
  let effort = match obj.get("effort") {
    Some(String(s)) => Some(s)
    None | Some(Null) => None
    Some(_) => return Err("herdr_delegate: optional 'effort' must be a string")
  }
  let session = match obj.get("session") {
    Some(String(s)) => Some(s)
    None | Some(Null) => None
    Some(_) =>
      return Err(
        "herdr_delegate: optional 'session' must be a child session id string",
      )
  }
  let timeout_ms = match obj.get("timeout_ms") {
    Some(Number(value, ..)) =>
      if value > 0.0 {
        value.to_int()
      } else {
        return Err("herdr_delegate: 'timeout_ms' must be a positive integer")
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
  Ok({
    task,
    permission,
    model,
    effort,
    session,
    timeout_ms,
    direction,
    close_pane,
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
/// then the concurrency guard, then arg validation, then the channel flow.
/// The in-flight counter is decremented on every exit path.
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
/// Herdr-context section for the assembled system prompt. Static text built
/// only from construction-time fields (pane is fixed), honoring the
/// byte-stability contract of SystemPromptContributor.
pub impl @posoco.SystemPromptContributor for HerdrDelegate with fn system_prompt(
  self : HerdrDelegate,
) -> String {
  "You are running inside a herdr terminal-multiplexer pane (pane \{self.pane}). You can delegate work to depth-1 cetas-headless child agents in visible panes with the herdr_delegate tool; children never receive delegation tools.\n" +
  "Use herdr_delegate for independent parallelizable subtasks (multiple calls in one response run as parallel panes, concurrency cap 4), for read-only reconnaissance first (permission=readonly), and for tasks that need process isolation or long runtime. Results are read back from the pane screen and long answers may truncate: tell children to write important artifacts to workspace files instead of long replies. Related or follow-up tasks MUST reuse the same child session — pass a result's child_session (also present on failure/timeout errors) back via the session argument. One work-stream = one child session; never open a fresh session for each step of the same logical task — reuse keeps context coherent and makes restarts after failure or timeout cheap.\n" +
  "write permission (--yolo) is powerful: prefer readonly unless the task must modify the workspace."
}

///|
pub impl @posoco.Extension for HerdrDelegate with fn extension_id(
  _self : HerdrDelegate,
) -> String {
  "posoco_ext_herdr_delegate"
}

///|
/// A HerdrDelegate contributes itself as a tool plus its herdr-context
/// system-prompt section. Everything else stays empty — the reporter's
/// presence manifest is untouched.
pub impl @posoco.Extension for HerdrDelegate with fn manifest(
  self : HerdrDelegate,
) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_herdr_delegate",
    models: [],
    tools: [self],
    sessions: [],
    observers: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [self],
    requires: [],
  }
}
