///|
#external
priv type NodeSpawnOptions

///|
#external
priv type CliProc

///|
#module("node:child_process")
extern "js" fn cp_spawn(
  file : String,
  args : FixedArray[String],
  options : NodeSpawnOptions,
) -> CliProc = "spawn"

///|
/// Spawn the Obsidian CLI with piped stdout+stderr; args cross the FFI as a JSON
/// array string.
extern "js" fn node_spawn_obsidian(
  spawn : (String, FixedArray[String], NodeSpawnOptions) -> CliProc,
  cli_path : String,
  args_json : String,
) -> CliProc =
  #| (spawn, cli_path, args_json) => {
  #|   const proc = spawn(cli_path, [...JSON.parse(args_json)], { stdio: ["ignore", "pipe", "pipe"] })
  #|   const drain = (stream) => stream
  #|     ? new Promise((resolve) => {
  #|         let text = ""
  #|         const finish = () => resolve(text)
  #|         stream.setEncoding("utf8")
  #|         stream.on("data", (chunk) => { text += chunk })
  #|         stream.on("end", finish)
  #|         stream.on("close", finish)
  #|         stream.on("error", finish)
  #|       })
  #|     : Promise.resolve("")
  #|   const exited = new Promise((resolve) => {
  #|     proc.on("close", (code) => resolve(code ?? -1))
  #|     proc.on("error", () => resolve(-1))
  #|   })
  #|   return { proc, exited, stdoutText: drain(proc.stdout), stderrText: drain(proc.stderr) }
  #| }

///|
extern "js" fn CliProc::exit_code(self : CliProc) -> @js_async.Promise[Int32] =
  #| (handle) => handle.exited

///|
extern "js" fn CliProc::stdout_text(
  self : CliProc,
) -> @js_async.Promise[String] =
  #| (handle) => handle.stdoutText

///|
extern "js" fn CliProc::stderr_text(
  self : CliProc,
) -> @js_async.Promise[String] =
  #| (handle) => handle.stderrText

///|
priv struct JsCliIo {}

///|
impl CliIo for JsCliIo with fn run(
  _self : JsCliIo,
  cli_path : String,
  args : Array[String],
) -> CliResult raise @posoco.RuntimeError {
  let json_args : Array[Json] = []
  for a in args {
    json_args.push(Json::string(a))
  }
  let args_json = Json::array(json_args).stringify()
  let proc = node_spawn_obsidian(cp_spawn, cli_path, args_json)
  let exit_code = proc.exit_code().wait() catch {
      _ =>
        raise @posoco.RuntimeError::InvocationFailed(
          "could not run the Obsidian CLI (\{cli_path}); install Obsidian 1.12+ and register its CLI",
        )
    }
  let stdout = proc.stdout_text().wait() catch { _ => "" }
  let stderr = proc.stderr_text().wait() catch { _ => "" }
  let output = if stderr.length() > 0 {
    if stdout.length() > 0 {
      stdout + "\n" + stderr
    } else {
      stderr
    }
  } else {
    stdout
  }
  { exit_code, output, }
}

///|
pub impl @posoco.ToolProvider for ObsidianTools with fn list_tools(
  self : ObsidianTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools(self.config)
}

///|
pub impl @posoco.ToolProvider for ObsidianTools with fn execute(
  self : ObsidianTools,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  self.execute_impl(JsCliIo::{ }, ctx.name.to_string(), {
    call_id: ctx.call_id,
    name: ctx.name,
    arguments: ctx.arguments,
  })
}

///|
pub impl @posoco.Lifecycle for ObsidianTools with fn on_start(
  self : ObsidianTools,
) -> Unit {
  let probe = run_cli(JsCliIo::{ }, self, ["version"]) catch { _ => return }
  ignore(probe)
}

///|
pub impl @posoco.Lifecycle for ObsidianTools with fn on_shutdown(
  _self : ObsidianTools,
) -> Unit {
  // No long-lived child processes: every CLI call is one spawn-and-collect.
}

///|
pub impl @posoco.CommandPort for ObsidianTools with fn commands(
  _self : ObsidianTools,
) -> Array[@posoco.CommandDef] {
  command_defs()
}

///|
pub impl @posoco.CommandPort for ObsidianTools with fn invoke(
  self : ObsidianTools,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  let cli_args : Array[String] = match id {
    "obsidian-open" =>
      match arg_string(args, "path") {
        Some(p) => ["open", "path=\{p}"]
        None =>
          return @posoco.CommandOutcome::Failure(
            reason="obsidian-open requires a path parameter",
          )
      }
    "obsidian-daily" => ["daily"]
    _ => return @posoco.CommandOutcome::Failure(reason="unknown command: \{id}")
  }
  let result = run_cli(JsCliIo::{ }, self, cli_args) catch {
    _ =>
      return @posoco.CommandOutcome::Failure(
        reason="could not run the Obsidian CLI",
      )
  }
  if cli_is_business_error(result) {
    return @posoco.CommandOutcome::Failure(reason=result.output)
  }
  @posoco.CommandOutcome::Success(
    feedback=result.output,
    structured=None,
    ui_hint=None,
  )
}

///|
pub extend ObsidianTools with @posoco.Lifecycle::{
  on_compose,
  on_shutdown,
  on_start,
}

///|
pub extend ObsidianTools with @posoco.CommandPort::{invoke, commands}
