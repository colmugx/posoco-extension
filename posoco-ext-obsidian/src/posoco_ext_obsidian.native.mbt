///|
/// Native adapter: run the CLI through `moonbitlang/async/process`.

///|
priv struct NativeCliIo {}

///|
impl CliIo for NativeCliIo with fn run(
  _self : NativeCliIo,
  cli_path : String,
  args : Array[String],
) -> CliResult raise @posoco.RuntimeError {
  let (exit_code, output_data) = @process.collect_output_merged(cli_path, args) catch {
    _ =>
      raise @posoco.RuntimeError::InvocationFailed(
        "could not spawn the Obsidian CLI (\{cli_path}); install Obsidian 1.12+ and register its CLI",
      )
  }
  let output = output_data.text() catch {
    _ =>
      raise @posoco.RuntimeError::InvocationFailed(
        "Obsidian CLI produced non-UTF-8 output",
      )
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
  self.execute_impl(NativeCliIo::{ }, name, call)
}

///|
/// Probe the CLI once per agent lifetime. Failure is not fatal: tools stay
/// listed and each call surfaces its own business error, because the CLI
/// auto-launches the desktop app and may simply have been cold at compose.
pub impl @posoco.Lifecycle for ObsidianTools with fn on_start(
  self : ObsidianTools,
) -> Unit {
  let probe = run_cli(NativeCliIo::{ }, self, ["version"]) catch { _ => return }
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
  let result = run_cli(NativeCliIo::{ }, self, cli_args) catch {
    _ =>
      return @posoco.CommandOutcome::Failure(
        reason="could not spawn the Obsidian CLI",
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
