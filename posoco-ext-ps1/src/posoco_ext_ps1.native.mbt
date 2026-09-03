///|
pub impl @posoco.ToolProvider for PowerShellTools with fn list_tools(
  self : PowerShellTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools(self.exe)
}

///|
pub impl @posoco.ToolProvider for PowerShellTools with fn execute(
  self : PowerShellTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let cmd = extract_command(call.arguments)
  if cmd == "" {
    raise ps1_empty_command_failure()
  }
  // cwd is passed explicitly (never inherited) when an anchor is set, so the
  // child cannot drift from the workspace root the model was told about.
  let (exit_code, output_data) = match self.anchor {
    Some(anchor) =>
      @process.collect_output_merged(
        self.exe,
        ["-NoProfile", "-NonInteractive", "-Command", cmd],
        cwd=anchor.root,
      ) catch {
        _ => raise ps1_collect_output_failure()
      }
    None =>
      @process.collect_output_merged(self.exe, [
        "-NoProfile", "-NonInteractive", "-Command", cmd,
      ]) catch {
        _ => raise ps1_collect_output_failure()
      }
  }
  // Decode failure must not masquerade as success. If the process produced
  // non-UTF-8 / undecodable output, surface it as a business-level error
  // (ToolReportedError) with a message that includes the exit code, so the
  // model can react instead of receiving a silent "(decoding error)" body on
  // an exit-0 success.
  let mut decode_failed = false
  let content = output_data.text() catch {
    _ => {
      decode_failed = true
      ps1_decode_failure(exit_code)
    }
  }
  let is_error = exit_code != 0 || decode_failed
  if is_error {
    @posoco.ToolOutcome::ToolReportedError(content~, structured=None)
  } else {
    @posoco.ToolOutcome::Success(content~, structured=None)
  }
}

///|
/// Native decode failure — non-UTF-8 output must not masquerade as success.
fn ps1_decode_failure(exit_code : Int) -> String {
  "powershell: decode failed (stage=decode_output, category=invalid_utf8, exit_code=\{exit_code})"
}

///|
/// Native collect_output failure.
fn ps1_collect_output_failure() -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "powershell: process failed (stage=collect_output)",
  )
}
