///|
/// Tool arguments parsed from call.arguments (pure, for tests).
pub(all) struct ZcodeTaskArgs {
  task : String
  cwd : String?
  session_id : String?
  mode : String?
} derive(Eq, Debug)

///|
pub(all) struct ZcodeTools {
  config : ZcodeConfig
}

///|
pub fn zcode_tools(config? : ZcodeConfig = zcode_config()) -> ZcodeTools {
  { config, }
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
      Ok({
        task,
        cwd: zcode_arg_string(map, "cwd"),
        session_id: zcode_arg_string(map, "session_id"),
        mode,
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
      description: "Delegate a task to the local zcode CLI — the GLM coding-plan official harness with its own plugins and skills. zcode plans, edits files and runs commands inside its own session in the given working directory, then returns its final answer. Pass session_id (from a previous result) to continue that session instead of starting a new one. Long-running: a delegation may take many minutes. Default mode is edit; dangerous operations are denied by the bridge and reported back in the result text.",
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
