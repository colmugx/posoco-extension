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
  mut host_group : @async.TaskGroup[Unit]?
  bus : @devkit.EventBus?
  sessions : Map[String, ShellSession]
  mut next_session : Int32
  mut closed : Bool
}

///|
/// Canonical constructor. Use this everywhere.
pub fn ShellTools::ShellTools(
  anchor~ : @devkit.WorkspaceAnchor? = None,
  bus~ : @devkit.EventBus? = None,
) -> ShellTools {
  ShellTools::{
    anchor,
    in_flight: Map::from_array([]),
    host_group: None,
    bus,
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
  mut exit_code : Int32?
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
fn ShellSession::active(self : ShellSession) -> Bool {
  self.status == "running" || self.status == "stopping"
}

///|
fn ShellSession::snapshot(self : ShellSession, cursor : Int64) -> Json {
  let now = @async.now()
  let offset = if cursor < self.base_cursor {
    0L
  } else if cursor > self.next_cursor {
    self.next_cursor - self.base_cursor
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
  match self.exit_code {
    Some(code) => fields["exit_code"] = Json::number(code.to_double())
    None => ()
  }
  if self.status == "failed" || self.status == "timed_out" {
    fields["failed"] = Json::boolean(true)
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
    if session.active() {
      running += 1
    }
  }
  running < BASH_MAX_RUNNING_SESSIONS &&
  self.sessions.length() < BASH_MAX_RETAINED_SESSIONS
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
              "background",
              Json::object(
                Map::from_array([
                  ("type", Json::string("boolean")),
                  (
                    "description",
                    Json::string(
                      "Start a host-owned background session and return immediately.",
                    ),
                  ),
                ]),
              ),
            ),
            (
              "yield_time_ms",
              Json::object(
                Map::from_array([
                  ("type", Json::string("integer")),
                  ("minimum", Json::number(0.0)),
                  ("maximum", Json::number(60000.0)),
                  (
                    "description",
                    Json::string(
                      "Foreground wait slice; returns a session if the child continues.",
                    ),
                  ),
                ]),
              ),
            ),
            (
              "timeout_ms",
              Json::object(
                Map::from_array([
                  ("type", Json::string("integer")),
                  (
                    "description",
                    Json::string(
                      "Hard runtime cap in milliseconds (default 300000, maximum 3600000).",
                    ),
                  ),
                  ("minimum", Json::number(1.0)),
                  ("maximum", Json::number(3600000.0)),
                ]),
              ),
            ),
          ]),
        ),
      ),
      // The executor accepts either name. Advertise both names to the schema
      // validator so it does not reject `command` before execute() can run.
      (
        "anyOf",
        Json::array([
          Json::object({ "required": Json::array([Json::string("cmd")]) }),
          Json::object({ "required": Json::array([Json::string("command")]) }),
        ]),
      ),
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
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("bash_status"),
      description: "Read the status and incremental output for a background Bash session.",
      input_schema: Json::object(
        Map::from_array([
          ("type", Json::string("object")),
          (
            "properties",
            Json::object(
              Map::from_array([
                (
                  "session_id",
                  Json::object(
                    Map::from_array([("type", Json::string("string"))]),
                  ),
                ),
                (
                  "cursor",
                  Json::object(
                    Map::from_array([("type", Json::string("integer"))]),
                  ),
                ),
              ]),
            ),
          ),
          ("required", Json::array([Json::string("session_id")])),
        ]),
      ),
      owner: @posoco.OwnerId::unchecked("posoco_ext_bash"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some("posoco_ext_bash"),
    },
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("bash_wait"),
      description: "Wait a bounded time for a background Bash session.",
      input_schema: Json::object(
        Map::from_array([
          ("type", Json::string("object")),
          (
            "properties",
            Json::object(
              Map::from_array([
                (
                  "session_id",
                  Json::object(
                    Map::from_array([("type", Json::string("string"))]),
                  ),
                ),
                (
                  "cursor",
                  Json::object(
                    Map::from_array([("type", Json::string("integer"))]),
                  ),
                ),
                (
                  "timeout_ms",
                  Json::object(
                    Map::from_array([("type", Json::string("integer"))]),
                  ),
                ),
              ]),
            ),
          ),
          ("required", Json::array([Json::string("session_id")])),
        ]),
      ),
      owner: @posoco.OwnerId::unchecked("posoco_ext_bash"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some("posoco_ext_bash"),
    },
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("bash_kill"),
      description: "Stop a background Bash session and its shell child.",
      input_schema: Json::object(
        Map::from_array([
          ("type", Json::string("object")),
          (
            "properties",
            Json::object(
              Map::from_array([
                (
                  "session_id",
                  Json::object(
                    Map::from_array([("type", Json::string("string"))]),
                  ),
                ),
              ]),
            ),
          ),
          ("required", Json::array([Json::string("session_id")])),
        ]),
      ),
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

///|
/// Session operations are independent of the cancelled foreground effect.
/// A background session can outlive a tool call only if the host explicitly
/// provided a task group. Detached sessions remain scoped to that host.
pub impl @posoco.ToolProvider for ShellTools with fn list_tools(
  _self : ShellTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
fn bash_field_str(
  args : Json,
  name : String,
) -> String raise @posoco.RuntimeError {
  match args {
    Json::Object(fields) =>
      match fields.get(name) {
        Some(Json::String(value)) => value
        _ =>
          raise @posoco.RuntimeError::UnknownTool(
            "bash: missing or invalid " + name,
          )
      }
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "bash: arguments must be an object",
      )
  }
}

///|
fn bash_field_int(
  args : Json,
  name : String,
  default : Int32,
  limit : Int32,
) -> Int32 raise @posoco.RuntimeError {
  match args {
    Json::Object(fields) =>
      match fields.get(name) {
        None => default
        Some(Json::Number(number, ..)) =>
          if number.floor() == number &&
            number >= 0.0 &&
            number <= limit.to_double() {
            number.to_int()
          } else {
            raise @posoco.RuntimeError::UnknownTool("bash: invalid " + name)
          }
        _ => raise @posoco.RuntimeError::UnknownTool("bash: invalid " + name)
      }
    _ => default
  }
}

///|
fn bash_background_requested(args : Json) -> Bool raise @posoco.RuntimeError {
  match args {
    Json::Object(fields) =>
      match fields.get("background") {
        None => false
        Some(Json::True) => true
        Some(Json::False) => false
        _ => raise @posoco.RuntimeError::UnknownTool("bash: invalid background")
      }
    _ => false
  }
}

///|
fn ShellTools::read_session(
  self : ShellTools,
  args : Json,
) -> ShellSession raise @posoco.RuntimeError {
  self.prune_sessions()
  let id = bash_field_str(args, "session_id")
  match self.sessions.get(id) {
    Some(session) => session
    None => raise @posoco.RuntimeError::UnknownTool("bash: unknown session_id")
  }
}

///|
/// Completion events are advisory, not an alternative to session snapshots.
/// A host can subscribe to bash.session.finished and bash.session.stall.
fn ShellTools::emit_session(
  self : ShellTools,
  session : ShellSession,
  topic : String,
) -> Unit {
  match self.bus {
    Some(bus) =>
      bus.publish({
        source: "posoco_ext_bash",
        topic,
        data: session.snapshot(session.next_cursor),
      })
    None => ()
  }
}

///|
/// Watch only for *suspected* stalls, not definitive deadlock. This watcher
/// belongs to the host group and stops once the command leaves running state.
async fn ShellTools::watch_stall(
  self : ShellTools,
  session : ShellSession,
) -> Unit {
  let mut warned = false
  while session.status == "running" {
    let idle = @async.now() - session.last_output_at_ms
    if idle >= BASH_STALL_WARNING_MS {
      if !warned {
        self.emit_session(session, "bash.session.stall")
        warned = true
      }
    } else {
      warned = false
    }
    @async.sleep(1000)
  }
}

///|
/// A command printing "timed out after" is not evidence of a deadline.
/// Only the runner's structured diagnostic can identify a real timeout.
fn bash_outcome_timed_out(outcome : @posoco.ToolOutcome) -> Bool {
  match outcome {
    @posoco.ToolOutcome::ToolReportedError(
      structured=Some(Json::Object(fields)),
      ..
    ) => fields.get("timed_out") is Some(Json::True)
    _ => false
  }
}

///|
fn bash_timeout_detail(timeout_ms : Int32) -> Json {
  Json::object(
    Map::from_array([
      ("timed_out", Json::boolean(true)),
      ("timeout_ms", Json::number(timeout_ms.to_double())),
    ]),
  )
}

///|
fn bash_session_outcome(snapshot : Json) -> @posoco.ToolOutcome {
  @posoco.ToolOutcome::Success(
    content=snapshot.stringify(),
    structured=Some(snapshot),
  )
}

///|
pub impl @posoco.ToolProvider for ShellTools with fn execute(
  self : ShellTools,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let tool = ctx.name.to_string()
  match tool {
    "bash_status" => {
      let session = self.read_session(ctx.arguments)
      let cursor = bash_field_int(ctx.arguments, "cursor", 0, 2147483647)
      bash_session_outcome(session.snapshot(cursor.to_int64()))
    }
    "bash_wait" => {
      let session = self.read_session(ctx.arguments)
      let cursor = bash_field_int(ctx.arguments, "cursor", 0, 2147483647)
      let ms = bash_field_int(ctx.arguments, "timeout_ms", 1000, 60000)
      let deadline = @async.now() + ms.to_int64()
      while session.active() && @async.now() < deadline {
        @async.sleep(50)
      }
      bash_session_outcome(session.snapshot(cursor.to_int64()))
    }
    "bash_kill" => {
      let session = self.read_session(ctx.arguments)
      if session.status == "running" {
        session.kill_requested = true
        session.status = "stopping"
      }
      match session.worker {
        Some(worker) => if session.status == "stopping" { worker.cancel() }
        None => ()
      }
      bash_session_outcome(session.snapshot(session.next_cursor))
    }
    "bash" => {
      let cmd = extract_command(ctx.arguments)
      if cmd == "" {
        raise bash_empty_command_failure()
      }
      let background = bash_background_requested(ctx.arguments)
      let yield_ms = bash_field_int(ctx.arguments, "yield_time_ms", 0, 60000)
      ignore(bash_timeout_ms(ctx.arguments))
      if !background && yield_ms == 0 {
        return self.bash_foreground(ctx)
      }
      if self.closed || self.host_group is None {
        raise @posoco.RuntimeError::InvocationFailed(
          "bash: background sessions require ShellTools.attach(host_group)",
        )
      }
      if !self.session_capacity() {
        raise @posoco.RuntimeError::InvocationFailed(
          "bash: too many background sessions",
        )
      }
      self.next_session += 1
      let number = self.next_session
      let id = "bash_" + @async.now().to_string() + "_" + number.to_string()
      let session : ShellSession = {
        id,
        effect_id: @kernel.EffectId::{ value: -number - 1000000, },
        started_at_ms: @async.now(),
        last_output_at_ms: @async.now(),
        ended_at_ms: None,
        status: "running",
        output: "",
        base_cursor: 0L,
        next_cursor: 0L,
        outcome: None,
        exit_code: None,
        worker: None,
        kill_requested: false,
      }
      self.sessions[id] = session
      let group = self.host_group.unwrap()
      let worker = group.spawn(async fn() {
        defer {
          self.in_flight.remove(session.effect_id.to_int())
          if session.status == "running" || session.status == "stopping" {
            session.status = if session.kill_requested {
              "killed"
            } else {
              "cancelled"
            }
            session.ended_at_ms = Some(@async.now())
          }
          self.emit_session(session, "bash.session.finished")
        }
        // Detached from the model effect's cancellation registration.
        let background_ctx : @posoco.ToolCallContext = {
          effect_id: session.effect_id,
          call_id: ctx.call_id,
          name: @posoco.ToolName::unchecked("bash"),
          arguments: ctx.arguments,
          register_cancel: fn(_ : &@posoco.ToolCancellable) { () },
        }
        let answer = Ok(
          self.bash_foreground(background_ctx, session=Some(session)),
        ) catch {
          error => Err(error)
        }
        match answer {
          Ok(outcome) => {
            session.outcome = Some(outcome)
            match outcome {
              @posoco.ToolOutcome::Success(..) => session.status = "completed"
              @posoco.ToolOutcome::ToolReportedError(..) =>
                session.status = if bash_outcome_timed_out(outcome) {
                  "timed_out"
                } else {
                  "failed"
                }
              _ => session.status = "failed"
            }
          }
          Err(error) => {
            session.append(error.to_string())
            session.status = "failed"
          }
        }
        session.ended_at_ms = Some(@async.now())
      })
      session.worker = Some(worker)
      self.emit_session(session, "bash.session.started")
      ignore(group.spawn(async fn() { self.watch_stall(session) }))
      if !background && yield_ms > 0 {
        let deadline = @async.now() + yield_ms.to_int64()
        while session.status == "running" && @async.now() < deadline {
          @async.sleep(50)
        }
        if session.status != "running" && session.outcome is Some(outcome) {
          return outcome
        }
      }
      bash_session_outcome(session.snapshot(0L))
    }
    _ => raise @posoco.RuntimeError::UnknownTool("bash: unknown tool " + tool)
  }
}

///|
/// Host shutdown requests cancellation for every session. The host's
/// attached task group remains responsible for joining its child tasks.
pub fn ShellTools::shutdown(self : ShellTools) -> Unit {
  self.closed = true
  for _, session in self.sessions {
    if session.active() {
      session.kill_requested = true
      session.status = "stopping"
      match session.worker {
        Some(worker) => worker.cancel()
        None => ()
      }
    }
  }
}

///|
pub impl @posoco.Lifecycle for ShellTools with fn on_shutdown(self) -> Unit {
  self.shutdown()
}

///|
pub extend ShellTools with @posoco.Lifecycle::{
  on_compose,
  on_start,
  on_shutdown,
}
