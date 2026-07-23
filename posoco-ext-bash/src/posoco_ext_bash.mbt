///|
/// ShellTools — unified shell tool provider (list + execute).
/// Provides bash and shell command execution tools on native target.
pub(all) struct ShellTools {}

///|
pub fn ShellTools::new() -> ShellTools {
  ShellTools::{  }
}

///|
fn bash_collect_output_failure() -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "bash: process failed (stage=collect_output)",
  )
}

///|
fn bash_decode_failure(exit_code : Int) -> String {
  "bash: decode failed (stage=decode_output, category=invalid_utf8, exit_code=\{exit_code})"
}

///|
pub impl @posoco.ToolProvider for ShellTools with fn list_tools(_self) -> Array[
  @posoco.ToolDef,
] {
  shared_list_tools()
}

///|
pub impl @posoco.ToolProvider for ShellTools with fn execute(
  _self,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  let cmd = extract_command(call.arguments)
  if cmd == "" {
    raise bash_empty_command_failure()
  }
  let (exit_code, output_data) = @process.collect_output_merged("sh", [
    "-c", cmd,
  ]) catch {
    _ => raise bash_collect_output_failure()
  }
  // T07-B: decode failure must not masquerade as success. If the process
  // produced non-UTF-8 / undecodable output, surface it as a business-level
  // error (is_error=true) with a message that includes the exit code, so the
  // model can react instead of receiving a silent "(decoding error)" body
  // on an exit-0 success.
  let mut decode_failed = false
  let content = output_data.text() catch {
    _ => {
      decode_failed = true
      bash_decode_failure(exit_code)
    }
  }
  @posoco.ToolResult::{
    content,
    structured: None,
    is_error: exit_code != 0 || decode_failed,
  }
}
