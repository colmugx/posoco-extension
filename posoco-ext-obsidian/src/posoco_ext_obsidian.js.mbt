///|
// js (bun) adapter: run the CLI through `Bun.spawn`. Bun is a global under
// bun, so the externs need no require/import. `@js_async.Promise::wait`
// returns the fulfilled value and raises on rejection.

///|
#external
priv type BunProc

///|
/// Spawn the Obsidian CLI with piped stdout+stderr. Synchronous in bun;
/// args cross the FFI as a JSON array string.
extern "js" fn bun_spawn_obsidian(
  cli_path : String,
  args_json : String,
) -> BunProc =
  #| (cli_path, args_json) => Bun.spawn({ cmd: [cli_path, ...JSON.parse(args_json)], stdout: "pipe", stderr: "pipe" })

///|
/// `Subprocess.prototype.exited` — Promise<number> (exit code).
extern "js" fn BunProc::exit_code(self : BunProc) -> @js_async.Promise[Int] =
  #| (proc) => proc.exited

///|
/// Drain stdout as UTF-8 string via `new Response(stream).text()`.
extern "js" fn BunProc::stdout_text(
  self : BunProc,
) -> @js_async.Promise[String] =
  #| (proc) => new Response(proc.stdout).text()

///|
/// Drain stderr as UTF-8 string.
extern "js" fn BunProc::stderr_text(
  self : BunProc,
) -> @js_async.Promise[String] =
  #| (proc) => new Response(proc.stderr).text()

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
  let proc = bun_spawn_obsidian(cli_path, args_json)
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
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  self.execute_impl(JsCliIo::{ }, name, call)
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
