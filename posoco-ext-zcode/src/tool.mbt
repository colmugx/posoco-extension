///|
/// Tool arguments parsed from call.arguments (pure, for tests).
pub(all) struct ZcodeTaskArgs {
  task : String
  cwd : String?
  session_id : String?
  mode : String?
  background : Bool
} derive(Eq, Debug)

///|
pub(all) struct ZcodeTools {
  config : ZcodeConfig
  /// The Agent-owned task capability, captured at on_compose from the
  /// Capability::Tasks the manifest requires; None before composition.
  mut tasks : @posoco.Tasks?
  /// Parent session of the operation currently executing, tracked from
  /// scoped observer events — background results are addressed to it.
  mut session : String?
  /// Background delegation runner (one CLI run → summary text); injectable
  /// for tests, default runs zcode_run_task + zcode_background_summary.
  background_run : async (ZcodeTaskArgs) -> String
}

///|
pub fn zcode_tools(
  config? : ZcodeConfig = zcode_config(),
  run? : (async (ZcodeTaskArgs) -> String)? = None,
) -> ZcodeTools {
  let runner : async (ZcodeTaskArgs) -> String = match run {
    Some(f) => f
    None =>
      async fn(args : ZcodeTaskArgs) {
        let cwd = match args.cwd {
          Some(c) => c
          None => zcode_cwd_default()
        }
        let mode = match args.mode {
          Some(m) => m
          None => config.default_mode
        }
        let result = zcode_run_task(
          config~,
          task=args.task,
          cwd~,
          session_id=args.session_id,
          mode~,
        )
        zcode_background_summary(result)
      }
  }
  { config, tasks: None, session: None, background_run: runner, }
}

///|
/// Summary text for one finished delegation (the follow-up message body):
/// the response, the session id line (so the model can resume), and the
/// usage line when known — same shape as the foreground result footer.
pub fn zcode_background_summary(result : ZcodeTaskResult) -> String {
  let mut content = result.final_text + "\n\nsession_id: " + result.session_id
  match result.usage {
    Some(usage) =>
      content = content +
        "\ntokens: input=\{usage.input_tokens} output=\{usage.output_tokens} total=\{usage.total_tokens}"
    None => ()
  }
  content
}

///|
fn zcode_arg_string(map : Map[String, Json], key : String) -> String? {
  match map.get(key) {
    Some(Json::String(value)) => Some(value)
    _ => None
  }
}

///|
/// Parse tool arguments. `task` is required and must be a non-empty string;
/// `mode` is validated with zcode_check_mode semantics; an absent mode falls
/// back to `default_mode`.
pub fn zcode_parse_args(
  arguments : Json,
  default_mode~ : String,
) -> Result[ZcodeTaskArgs, String] {
  match arguments {
    Json::Object(map) => {
      let task = match zcode_arg_string(map, "task") {
        Some(task) => task
        None => return Err("zcode: 'task' (non-empty string) is required")
      }
      if task == "" {
        return Err("zcode: 'task' must be a non-empty string")
      }
      let mode = match zcode_arg_string(map, "mode") {
        Some(raw) =>
          match zcode_check_mode(raw) {
            Ok(_) => Some(raw)
            Err(message) => return Err(message)
          }
        None => Some(default_mode)
      }
      let background = match map.get("background") {
        None => false
        Some(Json::True) => true
        Some(Json::False) => false
        Some(_) => return Err("zcode: 'background' must be a boolean")
      }
      if background && map.get("session_id") is Some(_) {
        return Err(
          "zcode: background mode starts a fresh session — resume via session_id is foreground-only (one in-flight prompt per session, upstream error 1308)",
        )
      }
      Ok({
        task,
        cwd: zcode_arg_string(map, "cwd"),
        session_id: zcode_arg_string(map, "session_id"),
        mode,
        background,
      })
    }
    _ => Err("zcode: arguments must be a JSON object")
  }
}

///|
/// Result → ToolOutcome text: the response body, a session_id line (so the
/// model can resume the session later) and a usage line when known.
/// failed / permission_denied surface as ToolReportedError so the model can
/// react instead of treating the text as work product.
pub fn zcode_format_outcome(result : ZcodeTaskResult) -> @posoco.ToolOutcome {
  let mut content = result.final_text + "\n\nsession_id: " + result.session_id
  match result.usage {
    Some(usage) =>
      content = content +
        "\ntokens: input=\{usage.input_tokens} output=\{usage.output_tokens} total=\{usage.total_tokens}"
    None => ()
  }
  if result.stop_reason == "success" {
    @posoco.ToolOutcome::Success(content~, structured=None)
  } else {
    @posoco.ToolOutcome::ToolReportedError(content~, structured=None)
  }
}

///|
fn zcode_tool_schema() -> Json {
  Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      (
        "properties",
        Json::object(
          Map::from_array([
            (
              "task",
              Json::object(
                Map::from_array([
                  ("type", Json::string("string")),
                  (
                    "description",
                    Json::string(
                      "The complete instruction to delegate to zcode (plain text).",
                    ),
                  ),
                ]),
              ),
            ),
            (
              "cwd",
              Json::object(
                Map::from_array([
                  ("type", Json::string("string")),
                  (
                    "description",
                    Json::string(
                      "Working directory for the zcode session; defaults to the current directory.",
                    ),
                  ),
                ]),
              ),
            ),
            (
              "session_id",
              Json::object(
                Map::from_array([
                  ("type", Json::string("string")),
                  (
                    "description",
                    Json::string(
                      "A previous zcode session id (sess_…) to continue; omit to start a new session.",
                    ),
                  ),
                ]),
              ),
            ),
            (
              "mode",
              Json::object(
                Map::from_array([
                  ("type", Json::string("string")),
                  (
                    "enum",
                    Json::array([
                      Json::string("build"),
                      Json::string("edit"),
                      Json::string("plan"),
                      Json::string("yolo"),
                    ]),
                  ),
                  (
                    "description",
                    Json::string(
                      "Permission mode; defaults to edit. yolo auto-approves and must be requested explicitly.",
                    ),
                  ),
                ]),
              ),
            ),
            (
              "background",
              Json::object(
                Map::from_array([
                  ("type", Json::string("boolean")),
                  (
                    "description",
                    Json::string(
                      "Return a receipt immediately and run the delegation in the background; the result arrives later as a follow-up turn. Background always starts a fresh session.",
                    ),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
      ("required", Json::array([Json::string("task")])),
    ]),
  )
}

///|
pub impl @posoco.ToolProvider for ZcodeTools with fn list_tools(
  _self : ZcodeTools,
) -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("zcode"),
      description: "Delegate a task to the local zcode CLI — the GLM coding-plan official harness with its own plugins and skills. zcode plans, edits files and runs commands inside its own session in the given working directory, then returns its final answer. Pass session_id (from a previous result) to continue that session instead of starting a new one. Long-running: a delegation may take many minutes — pass background: true to get an immediate receipt and receive the result as a follow-up turn. Default mode is edit; dangerous operations are denied by the bridge and reported back in the result text.",
      input_schema: zcode_tool_schema(),
      owner: @posoco.OwnerId::unchecked("placeholder"),
      policy: @posoco.ExecutionPolicy::Sequential,
      provenance: Some("posoco_ext_zcode"),
    },
  ]
}

///|
/// Spec §8 error mapping: transport-shaped failures (spawn, timeout, dead
/// process, missing binary/credentials) raise RuntimeError::Transport;
/// server-side rejections (rpc error, model config, protocol) raise
/// RuntimeError::InvocationFailed, with a repair hint for model-config.
fn zcode_runtime_error(
  error : ZcodeError,
  timeout_ms : Int,
) -> @posoco.RuntimeError {
  let message = match error {
    ZcodeTimeout => "zcode: delegation exceeded the \{timeout_ms}ms wall clock"
    ZcodeProcessDied(detail~) => "zcode: app-server died: \{detail}"
    ZcodeSpawnFailed(detail~) => "zcode: spawn failed: \{detail}"
    ZcodeBinNotFound =>
      "zcode: binary not found (install the ZCode app or set ZCODE_BIN)"
    ZcodeCredsUnreadable(detail~) => "zcode: credentials unreadable: \{detail}"
    ZcodeRpc(code~, message~) =>
      "zcode: app-server rpc error (code \{code}): \{message}"
    ZcodeModelConfig(detail~) =>
      "zcode: model config rejected: \{detail} (check ~/.zcode/v2/config.json / provider registry)"
    ZcodeProtocol(detail~) => "zcode: protocol violation: \{detail}"
  }
  match error {
    ZcodeRpc(..) | ZcodeModelConfig(..) | ZcodeProtocol(..) =>
      @posoco.RuntimeError::InvocationFailed(message)
    _ => @posoco.RuntimeError::Transport(message)
  }
}

///|
pub impl @posoco.ToolProvider for ZcodeTools with fn execute(
  self : ZcodeTools,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  if name != "zcode" {
    raise @posoco.RuntimeError::UnknownTool(
      "posoco_ext_zcode: no tool named '\{name}'",
    )
  }
  let args = match
    zcode_parse_args(call.arguments, default_mode=self.config.default_mode) {
    Ok(args) => args
    Err(message) =>
      return @posoco.ToolOutcome::ToolReportedError(
        content=message,
        structured=None,
      )
  }
  if args.background {
    return self.background_execute(args)
  }
  let mode = match args.mode {
    Some(m) => m
    None => self.config.default_mode
  }
  let cwd = match args.cwd {
    Some(c) => c
    None => zcode_cwd_default()
  }
  let outcome : Result[ZcodeTaskResult, ZcodeError] = Ok(
    zcode_run_task(
      config=self.config,
      task=args.task,
      cwd~,
      session_id=args.session_id,
      mode~,
    ),
  ) catch {
    err => Err(err)
  }
  match outcome {
    Ok(result) => zcode_format_outcome(result)
    Err(error) => raise zcode_runtime_error(error, self.config.timeout_ms)
  }
}

///|
/// Background path: submit the delegation to the Agent-owned task capability
/// (captured at on_compose) and return the receipt text. The delegation runs
/// inside the host agent's run_scoped scope under the config timeout; core
/// delivers its terminal summary to the parent session as a follow-up turn.
/// There is deliberately no extension-side queue: an uncommitted outcome is
/// retained and retried by core on the next same-session ordinary turn.
#warnings("-fragile_catch_all")
fn ZcodeTools::background_execute(
  self : ZcodeTools,
  args : ZcodeTaskArgs,
) -> @posoco.ToolOutcome {
  let tasks = match self.tasks {
    Some(tasks) => tasks
    None =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="zcode: background mode requires the composed task capability — compose ZcodeExt's manifest (requires Tasks) and run the host agent under Agent::run_scoped",
        structured=None,
      )
  }
  let parent_session = match self.session {
    Some(session) => session
    None =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="zcode: no parent session observed yet — background results are addressed to the session whose run invoked this tool",
        structured=None,
      )
  }
  let run = self.background_run
  let accepted = tasks.submit({
    session_id: parent_session,
    mode: @posoco.TaskMode::Background,
    label: "zcode",
    timeout_ms: Some(self.config.timeout_ms),
    run: async fn() {
      let text = run(args) catch {
        error => {
          // A cancelled coroutine stays cancelled: pause() re-raises the
          // genuine cancellation (a suberror that flows through any typed
          // error channel) so the task group records this task as cancelled
          // rather than failed, and core's timeout classification survives
          // the delegation runner's error masking. Without a cancellation
          // the pause is a no-op yield and the original error propagates.
          @async.pause()
          raise error
        }
      }
      // Same guard on the return path: a cancellation the runner swallowed
      // into a returned value is converted back into a real cancellation;
      // without a pending cancellation the pause is a no-op yield.
      @async.pause()
      @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)])
    },
  })
  match accepted {
    Ok(handle) => {
      let receipt = handle.receipt()
      @posoco.ToolOutcome::Success(
        content="background zcode accepted\ndelegation_id: \{receipt.id}\na fresh zcode session will start; the result arrives as a follow-up turn",
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
    Err(@posoco.TaskSubmitError::Unavailable) =>
      @posoco.ToolOutcome::ToolReportedError(
        content="zcode: background submit unavailable — the host agent is not running under Agent::run_scoped",
        structured=None,
      )
    Err(@posoco.TaskSubmitError::Closed) =>
      @posoco.ToolOutcome::ToolReportedError(
        content="zcode: background submit refused — the agent is shut down",
        structured=None,
      )
    Err(@posoco.TaskSubmitError::QueueFull) =>
      @posoco.ToolOutcome::ToolReportedError(
        content="zcode: background queue full — retry shortly",
        structured=None,
      )
    Err(@posoco.TaskSubmitError::InvalidSession(reason~)) =>
      @posoco.ToolOutcome::ToolReportedError(
        content="zcode: background submit refused (invalid session): \{reason}",
        structured=None,
      )
  }
}
