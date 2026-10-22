///|
/// ShellTools — shell command execution tool provider.
///
/// When `anchor` is set, every command runs in a fresh shell with its
/// working directory pinned to the anchor root; when unset, the child
/// inherits the host process working directory (legacy behavior).
///
/// On native and wasm, executes via `@process.collect_output_merged("sh", ...)`.
/// On js, executes via node:child_process (runs under both bun and node). On wasm-gc, the tool is not
/// listed and execute raises `RuntimeError::InvocationFailed`.
///
/// The provider is also `ToolCancellable`: `bash` spawns register their
/// child under the call's `effect_id` via `ToolCallContext.register_cancel`,
/// so an aborted turn kills the child instead of orphaning it
/// (signal → grace window → hard kill).
pub struct ShellTools {
  anchor : @devkit.WorkspaceAnchor?
  /// Live shell children keyed by effect id. Entries whose execute path
  /// already completed are dropped; unwind-only cleanup may leave a stale
  /// exited entry, pruned by the next cancel.
  in_flight : Map[Int32, ShellChildHandle]
  /// Background work must be hosted by an explicit owner task group.
  host_group : @async.TaskGroup[Unit]?
  sessions : Map[String, ShellSession]
  mut next_session : Int32
  mut closed : Bool
}

///|
/// Canonical constructor. Use this everywhere.
pub fn ShellTools::ShellTools(
  anchor~ : @devkit.WorkspaceAnchor? = None,
) -> ShellTools {
  ShellTools::{
    anchor,
    in_flight: Map::from_array([]),
    host_group: None,
    sessions: Map::from_array([]),
    next_session: 0,
    closed: false,
  }
}

///|
/// Grace window between the interrupt signal and the hard kill, matching
/// the native spawn's `graceful_cancel` timeout so both escalation paths
/// agree.
let shell_cancel_grace_ms : Int32 = 2000

///|
/// Host-owned background sessions. This is deliberately separate from effect
/// cancellation: tool calls may settle while their commands keep running.
pub struct ShellSession {
  id : String
  effect_id : @kernel.EffectId
  started_at_ms : Int64
  mut last_output_at_ms : Int64
  mut ended_at_ms : Int64?
  mut status : String
  mut output : String
  mut base_cursor : Int64
  mut next_cursor : Int64
  mut outcome : @posoco.ToolOutcome?
  mut worker : @async.Task[Unit]?
  mut kill_requested : Bool
}

///|
/// Attach a task group owned by the host, with a lifetime longer than tool
/// calls. Detached execution is disabled until the host explicitly attaches.
pub fn ShellTools::attach(
  self : ShellTools,
  group : @async.TaskGroup[Unit],
) -> Unit {
  self.host_group = Some(group)
}

///|
const BASH_MAX_RUNNING_SESSIONS = 8

///|
const BASH_MAX_RETAINED_SESSIONS = 32

///|
const BASH_SESSION_TTL_MS = 600_000L

///|
const BASH_STALL_WARNING_MS = 60_000L

///|
fn bash_drop_chars(text : String, count : Int64) -> String {
  let output : Array[Char] = []
  let mut at = 0L
  for ch in text {
    if at >= count {
      output.push(ch)
    }
    at += 1L
  }
  String::from_array(output)
}

///|
/// A finite tail window with monotonic character cursors. Old output drops
/// without accumulating indefinitely, and clients can detect missing logs.
fn ShellSession::append(self : ShellSession, chunk : String) -> Unit {
  if chunk == "" {
    return
  }
  self.last_output_at_ms = @async.now()
  self.next_cursor += bash_char_count(chunk).to_int64()
  let combined = self.output + chunk
  let count = bash_char_count(combined)
  if count > BASH_OUTPUT_CHAR_CAP {
    self.output = bash_tail_chars(combined, count, BASH_OUTPUT_CHAR_CAP)
    self.base_cursor = self.next_cursor - BASH_OUTPUT_CHAR_CAP.to_int64()
  } else {
    self.output = combined
  }
}

///|
fn ShellSession::snapshot(self : ShellSession, cursor : Int64) -> Json {
  let now = @async.now()
  let offset = if cursor < self.base_cursor {
    0L
  } else if cursor > self.next_cursor {
    (self.next_cursor - self.base_cursor)
  } else {
    cursor - self.base_cursor
  }
  let idle_ms = if self.status == "running" {
    (now - self.last_output_at_ms).max(0L)
  } else {
    0L
  }
  let suspected_stall = self.status == "running" &&
    idle_ms >= BASH_STALL_WARNING_MS &&
    now - self.started_at_ms >= BASH_STALL_WARNING_MS
  let fields : Map[String, Json] = Map::from_array([
    ("session_id", Json::string(self.id)),
    ("status", Json::string(self.status)),
    ("output", Json::string(bash_drop_chars(self.output, offset))),
    ("cursor", Json::number(self.next_cursor.to_double())),
    ("truncated", Json::boolean(cursor < self.base_cursor)),
    ("idle_ms", Json::number(idle_ms.to_double())),
    ("suspected_stall", Json::boolean(suspected_stall)),
  ])
  match self.outcome {
    Some(@posoco.ToolOutcome::Success(..)) =>
      fields["exit_code"] = Json::number(0.0)
    Some(@posoco.ToolOutcome::ToolReportedError(..)) =>
      fields["failed"] = Json::boolean(true)
    _ => ()
  }
  Json::object(fields)
}

///|
fn ShellTools::prune_sessions(self : ShellTools) -> Unit {
  let old : Array[String] = []
  for id, session in self.sessions {
    if session.ended_at_ms is Some(at) &&
      @async.now() - at >= BASH_SESSION_TTL_MS {
      old.push(id)
    }
  }
  for id in old {
    self.sessions.remove(id)
  }
}

///|
fn ShellTools::session_capacity(self : ShellTools) -> Bool {
  self.prune_sessions()
  let mut running = 0
  for _, session in self.sessions {
    if session.status == "running" {
      running += 1
    }
  }
  running < BASH_MAX_RUNNING_SESSIONS &&
  self.sessions.size() < BASH_MAX_RETAINED_SESSIONS
}


///|
/// Terminate a registered shell child: signal, wait out the grace period,
/// then hard-kill. Stale exited entries left by unwind-only cleanup are
/// pruned first. Reports `Propagated` when a live child was handled.
pub impl @posoco.ToolCancellable for ShellTools with fn cancel(
  self,
  effect_id : @kernel.EffectId,
  _reason : @kernel.CancelReason,
) -> @kernel.CancelDisposition {
  let stale : Array[Int32] = []
  for key, handle in self.in_flight {
    if handle.exited {
      stale.push(key)
    }
  }
  for key in stale {
    self.in_flight.remove(key)
  }
  let key = effect_id.to_int()
  match self.in_flight.get(key) {
    Some(handle) => {
      shell_child_interrupt(handle)
      let exited = shell_child_await_exit(handle, shell_cancel_grace_ms + 500)
      if !exited {
        shell_child_hard_kill(handle)
      }
      self.in_flight.remove(key)
      @kernel.CancelDisposition::Propagated
    }
    None => @kernel.CancelDisposition::NotPropagated
  }
}

///|
/// Hard cap for model-visible shell output. This bounds transcript growth even
/// when a build/test command emits an unbounded log.
const BASH_OUTPUT_CHAR_CAP = 32_768

///|
/// Preserve a small prefix so command headers/context survive truncation;
/// spend the remaining budget on the tail where diagnostics usually land.
const BASH_OUTPUT_HEAD_CHARS = 4_096

///|
/// Hard wall-clock deadline for every shell command (5 minutes by default).
const BASH_DEFAULT_TIMEOUT_MS = 300_000

///|
const BASH_MAX_TIMEOUT_MS = 3_600_000

///|
/// Descendants may hold inherited pipe handles after the direct child exits.
const BASH_DRAIN_GRACE_MS = 1_000

///|
/// Bound accumulated output *during* streaming rather than only when returning.
fn bash_append_output(previous : String, chunk : String) -> String {
  let combined = previous + chunk
  let chars = bash_char_count(combined)
  if chars <= BASH_OUTPUT_CHAR_CAP {
    return combined
  }
  let marker = "\n…[cut]…\n"
  bash_take_chars(combined, BASH_OUTPUT_HEAD_CHARS) +
  marker +
  bash_tail_chars(
    combined,
    chars,
    BASH_OUTPUT_CHAR_CAP - BASH_OUTPUT_HEAD_CHARS - bash_char_count(marker),
  )
}

///|
/// Validate the optional process runtime cap, rejecting invalid arguments.
fn bash_timeout_ms(args : Json) -> Int32 raise @posoco.RuntimeError {
  match args {
    Json::Object(map) =>
      match map.get("timeout_ms") {
        None => BASH_DEFAULT_TIMEOUT_MS
        Some(Json::Number(value, ..)) =>
          if value < 1.0 ||
            value > BASH_MAX_TIMEOUT_MS.to_double() ||
            value.floor() != value {
            raise @posoco.RuntimeError::UnknownTool(
              "bash: timeout_ms must be an integer between 1 and 3600000",
            )
          } else {
            value.to_int()
          }
        _ =>
          raise @posoco.RuntimeError::UnknownTool(
            "bash: timeout_ms must be an integer between 1 and 3600000",
          )
      }
    _ => BASH_DEFAULT_TIMEOUT_MS
  }
}


///|
fn bash_char_count(text : String) -> Int32 {
  let mut count = 0
  for _ in text {
    count += 1
  }
  count
}

///|
fn bash_take_chars(text : String, limit : Int32) -> String {
  let chars : Array[Char] = []
  let mut taken = 0
  for ch in text {
    if taken >= limit {
      break
    }
    chars.push(ch)
    taken += 1
  }
  String::from_array(chars)
}

///|
fn bash_tail_chars(text : String, total_chars : Int32, limit : Int32) -> String {
  if limit <= 0 {
    return ""
  }
  let skip = total_chars - limit
  let chars : Array[Char] = []
  let mut index = 0
  for ch in text {
    if index >= skip {
      chars.push(ch)
    }
    index += 1
  }
  String::from_array(chars)
}

///|
/// Normalize shell output for the model:
/// - successful short output is unchanged;
/// - non-zero exits expose the exit code once;
/// - long output is bounded to BASH_OUTPUT_CHAR_CAP with head+tail context.
fn bash_model_output(content : String, exit_code : Int32) -> String {
  let raw = if exit_code == 0 {
    content
  } else if content == "" {
    "exit=\{exit_code}"
  } else {
    "exit=\{exit_code}\n\{content}"
  }
  let raw_chars = bash_char_count(raw)
  if raw_chars <= BASH_OUTPUT_CHAR_CAP {
    return raw
  }
  let marker = "\n…[cut]…\n"
  let tail_chars = BASH_OUTPUT_CHAR_CAP -
    BASH_OUTPUT_HEAD_CHARS -
    bash_char_count(marker)
  bash_take_chars(raw, BASH_OUTPUT_HEAD_CHARS) +
  marker +
  bash_tail_chars(raw, raw_chars, tail_chars)
}

// ToolProvider is split into two complete #cfg partitions (native/wasm/js real, wasm-gc inert); shared_list_tools avoids duplicating the ToolDef construction.

///|
/// Shared tool list (bash only). Both native and js ShellTools expose the
/// same single tool definition; only `execute` differs per target.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  // OpenAI/DeepSeek tool schema requires `parameters` to be a JSON Schema with
  // `type: "object"`; strict servers otherwise reject with HTTP 400
  // (`invalid_union_discriminator`).
  let cmd_schema : Json = Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      (
        "properties",
        Json::object(
          Map::from_array([
            (
              "cmd",
              Json::object(
                Map::from_array([
                  ("type", Json::string("string")),
                  ("description", Json::string("Shell command")),
                ]),
              ),
            ),
            (
              "timeout_ms",
              Json::object(
                Map::from_array([
                  ("type", Json::string("integer")),
                  ("description", Json::string("Hard runtime cap in milliseconds (default 300000, maximum 3600000).")),
                  ("minimum", Json::number(1.0)),
                  ("maximum", Json::number(3600000.0)),

                ]),
              ),
            ),
          ]),
        ),
      ),
      ("required", Json::array([Json::string("cmd")])),
    ]),
  )
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("bash"),
      description: "Run a shell command for builds, tests, git, or pipelines. Fresh shell at workspace root; `cd` does not persist. Hard runtime timeout defaults to 300000ms; override using timeout_ms.",
      input_schema: cmd_schema,
      owner: @posoco.OwnerId::unchecked("posoco_ext_bash"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some("posoco_ext_bash"),
    },
  ]
}

///|
/// Extract command string from ToolCall arguments JSON.
/// A missing or non-String cmd/command is a typed error, not a silent fallback
/// that runs the entire JSON blob as a shell command.
fn extract_command(args : Json) -> String raise @posoco.RuntimeError {
  match args {
    Json::Object(map) =>
      if map.contains("cmd") {
        match map["cmd"] {
          Json::String(s) => s
          _ =>
            raise @posoco.RuntimeError::UnknownTool(
              "bash: 'cmd' must be a string",
            )
        }
      } else if map.contains("command") {
        match map["command"] {
          Json::String(s) => s
          _ =>
            raise @posoco.RuntimeError::UnknownTool(
              "bash: 'command' must be a string",
            )
        }
      } else {
        raise @posoco.RuntimeError::UnknownTool("bash: missing 'cmd'")
      }
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "bash: arguments must be an object",
      )
  }
}

///|
/// Shared empty-command error (used by both native + js execute paths).
fn bash_empty_command_failure() -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed("bash: empty cmd")
}

///|
/// Per-target import keepers: each backend compiles only one execute path,
/// so the other backend's import would trip `unused_package`. `@process`
/// backs the native runner, `@js_async` the bun runner.
#cfg(target="js")
let _process_import_keeper : Unit = ignore(@process.unimplemented)

///|
#cfg(not(target="js"))
// The reference intentionally targets the native js_async stub, whose
// unimplemented alert is noise for a value that is never evaluated.
#warnings("-alert_unimplemented")
let _js_async_import_keeper : Unit = ignore(@js_async.AbortController::new)
