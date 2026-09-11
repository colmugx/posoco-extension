///|
/// Result of one delegation.
pub(all) struct ZcodeTaskResult {
  session_id : String
  title : String
  final_text : String
  /// success | failed | permission_denied
  stop_reason : String
  usage : ZcodeUsage?
} derive(Eq, Debug)

///|
/// The target seam. Each backend file (task.native.mbt over
/// moonbitlang/async process/fs, task.js.mbt over Bun) implements
/// `zcode_resolve_command_io`, `zcode_registry_io`, `zcode_cwd_default` and
/// `zcode_session_run`; everything else — arg parsing, protocol codecs,
/// registry building, result assembly, ToolProvider — stays in shared files.

///|
/// The task-group/timeout primitives raise the top `Error` type, while this
/// API is typed `raise ZcodeError`. Every error that actually flows through
/// a delegation is a ZcodeError value, so a plain variant match recovers it.
/// Anything else reaching here (host cancellation mid-teardown) is reported
/// as ZcodeProcessDied with the original message in the detail.
fn zcode_raise_typed(err : Error) -> ZcodeError {
  match err {
    ZcodeBinNotFound => ZcodeBinNotFound
    ZcodeSpawnFailed(detail~) => ZcodeSpawnFailed(detail~)
    ZcodeCredsUnreadable(detail~) => ZcodeCredsUnreadable(detail~)
    ZcodeProtocol(detail~) => ZcodeProtocol(detail~)
    ZcodeRpc(code~, message~) => ZcodeRpc(code~, message~)
    ZcodeModelConfig(detail~) => ZcodeModelConfig(detail~)
    ZcodeTimeout => ZcodeTimeout
    ZcodeProcessDied(detail~) => ZcodeProcessDied(detail~)
    _ => ZcodeProcessDied(detail="zcode delegation failed: \{err}")
  }
}

///|
/// One delegation: spawn → bootstrap (registry push) → create/resume →
/// subscribe → send → reduce events to a terminal → teardown. One task = one
/// app-server process; session continuity crosses processes via
/// session/resume.
pub async fn zcode_run_task(
  config~ : ZcodeConfig,
  task~ : String,
  cwd~ : String,
  session_id~ : String?,
  mode~ : String,
) -> ZcodeTaskResult raise ZcodeError {
  let cmd = zcode_resolve_command_io(config~)
  let registry = zcode_registry_io(config~)
  let outcome : Result[ZcodeTaskResult, Error] = Ok(
    zcode_session_run(cmd, registry, config~, task~, cwd~, session_id~, mode~),
  ) catch {
    err => Err(err)
  }
  match outcome {
    Ok(result) => result
    Err(err) => raise zcode_raise_typed(err)
  }
}
