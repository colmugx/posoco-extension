///|
/// Native backend of the task seam (moonbitlang/async process + fs): the
/// ZcodeConn line protocol, reverse-request policy, event collection and
/// teardown.

///|
/// One delegation's live connection. Concurrency model: MoonBit async is a
/// single-threaded cooperative event loop, so plain field accesses between
/// await points are race-free. The only await-spanning resource is the stdin
/// writer — both the request issuer and the reader task (reverse-request
/// replies) push lines — so every line write takes `write_lock`; a partial
/// pipe write can then never interleave with another line. The pending map
/// is keyed by the stringified request id; each entry is a one-shot queue
/// completed by the reader (or failed by it on EOF).
priv struct ZcodeConn {
  pending : Map[String, @aqueue.Queue[Result[Json, ZcodeError]]]
  events : @aqueue.Queue[ZcodeEvent]
  writer : @io.BufferedWriter[@process.WriteToProcess]
  raw_writer : @process.WriteToProcess
  write_lock : @async.Mutex
  mut next_id : Int
  /// Summary of the last denied `interaction/requestPermission`; set by the
  /// reader task, read after the turn ends.
  mut denial : String?
}

///|
async fn ZcodeConn::write_line(
  self : ZcodeConn,
  line : String,
) -> Unit raise ZcodeError {
  self.write_lock.acquire() catch {
    _ => ()
  }
  try {
    self.writer.write(line)
    self.writer.write("\n")
    self.writer.flush()
  } catch {
    e => {
      self.write_lock.release()
      raise ZcodeProcessDied(detail="zcode: stdin write failed: \{e}")
    }
  }
  self.write_lock.release()
}

///|
/// One request/response round trip. The reader task completes the pending
/// queue (or fails it with ZcodeProcessDied on EOF); a queue that is already
/// closed by the time we await it degrades to the same ZcodeProcessDied.
async fn ZcodeConn::request(
  self : ZcodeConn,
  method_name : String,
  params : Json?,
) -> Result[Json, ZcodeError] raise ZcodeError {
  self.next_id = self.next_id + 1
  let id = Json::number(self.next_id.to_double())
  let queue : @aqueue.Queue[Result[Json, ZcodeError]] = @aqueue.Queue(
    kind=Blocking(1),
  )
  self.pending[id.stringify()] = queue
  self.write_line(Request(id~, method_name~, params~).to_line())
  let reply : Result[Json, ZcodeError] = queue.get() catch {
    _ =>
      Err(
        ZcodeProcessDied(
          detail="zcode: connection closed before the response arrived",
        ),
      )
  }
  let _ = self.pending.remove(id.stringify())
  reply
}

///|
/// Decode and dispatch one inbound line. A failed reply write propagates so
/// the read loop can wind down; a bad line is dropped.
async fn ZcodeConn::handle_line(
  self : ZcodeConn,
  line : String,
) -> Unit raise ZcodeError {
  match zcode_wire_decode(line) {
    Ok(Response(id~, result~, error~)) => {
      let key = id.stringify()
      match self.pending.get(key) {
        Some(queue) => {
          let _ = self.pending.remove(key)
          let reply : Result[Json, ZcodeError] = match error {
            Some(e) => Err(ZcodeRpc(code=e.code, message=e.message))
            None => Ok(result.unwrap_or(Json::null()))
          }
          queue.put(reply) catch {
            _ => ()
          }
        }
        None => ()
      }
    }
    Ok(Request(id~, method_name~, params~)) =>
      self.answer_request(id, method_name, params)
    Ok(Notification(method_name~, params~)) =>
      if method_name == "session/event" {
        match params {
          Some(p) => {
            let event = zcode_reduce_notification(
              method_name,
              zcode_merge_event_params(p),
            )
            match event {
              Some(e) => {
                let _ = self.events.try_put(e) catch { _ => false }
              }
              None => ()
            }
          }
          None => ()
        }
      }
    Err(_) => ()
  }
}

///|
/// §7 reverse-request policy: never allow anything, never let the server
/// hang on an unknown request.
async fn ZcodeConn::answer_request(
  self : ZcodeConn,
  id : Json,
  method_name : String,
  params : Json?,
) -> Unit raise ZcodeError {
  match method_name {
    "session/requestRuntimePreferences" => {
      let result = Json::object(
        Map::from_array([
          ("nativeSearchEnhancementsEnabled", Json::boolean(false)),
          ("memoryEnabled", Json::boolean(false)),
        ]),
      )
      self.write_line(Response(id~, result=Some(result), error=None).to_line())
    }
    "interaction/requestOfficialMcpAuthHeaders" => {
      let result = Json::object(Map::from_array([]))
      self.write_line(Response(id~, result=Some(result), error=None).to_line())
    }
    "interaction/requestPermission" =>
      match zcode_permission_deny(params) {
        Some((option_json, summary)) => {
          self.denial = Some(summary)
          self.write_line(
            Response(id~, result=Some(option_json), error=None).to_line(),
          )
        }
        None =>
          self.write_line(
            Response(
              id~,
              result=None,
              error=Some(
                zcode_refuse("no deny option found in the permission request"),
              ),
            ).to_line(),
          )
      }
    "interaction/requestUserInput" =>
      self.write_line(
        Response(
          id~,
          result=None,
          error=Some(zcode_refuse("user input not bridged")),
        ).to_line(),
      )
    _ =>
      self.write_line(
        Response(
          id~,
          result=None,
          error=Some({ code: -32601, message: "Method not found", data: None, }),
        ).to_line(),
      )
  }
}

///|
fn zcode_refuse(message : String) -> ZcodeRpcError {
  { code: -32600, message: "cetas: " + message, data: None, }
}

///|
/// Real session/event notifications nest the event fields under
/// `params.payload` (driver.py reads `params.type` + `payload.*`), while the
/// reducer expects them flat next to `type`. Merge both into one
/// object; params-level keys win. Payload-less params pass through unchanged.
fn zcode_merge_event_params(params : Json) -> Json {
  match params {
    Json::Object(map) =>
      match map.get("payload") {
        Some(Json::Object(payload)) => {
          let merged : Map[String, Json] = Map::from_array([])
          for key, value in payload {
            merged[key] = value
          }
          for key, value in map {
            merged[key] = value
          }
          Json::object(merged)
        }
        _ => params
      }
    _ => params
  }
}

///|
/// Pick the first deny/reject option of a permission request (defensive
/// read — the payload shape is unverified live, ZX-5). Returns the reply
/// result plus a human summary for ZcodeTaskResult. Never returns an allow.
fn zcode_permission_deny(params : Json?) -> (Json, String)? {
  match params {
    Some(Json::Object(map)) => {
      let options = match map.get("options") {
        Some(Json::Array(opts)) => opts
        _ => []
      }
      for option in options {
        match option {
          Json::Object(o) => {
            let kind = match o.get("kind") {
              Some(Json::String(k)) => k
              _ =>
                match o.get("type") {
                  Some(Json::String(k)) => k
                  _ => ""
                }
            }
            let denyish = kind.contains("deny") ||
              kind.contains("reject") ||
              kind.contains("Deny") ||
              kind.contains("Reject")
            if denyish {
              let option_id = match o.get("optionId") {
                Some(Json::String(id)) => id
                _ =>
                  match o.get("id") {
                    Some(Json::String(id)) => id
                    _ => ""
                  }
              }
              let tool_name = match map.get("toolName") {
                Some(Json::String(t)) => t
                _ => ""
              }
              let reason = match map.get("reason") {
                Some(Json::String(r)) => r
                _ => ""
              }
              let summary = "zcode asked for permission for tool '\{tool_name}' (\{reason}) and was denied by cetas"
              let result = Json::object(
                Map::from_array([("optionId", Json::string(option_id))]),
              )
              return Some((result, summary))
            }
          }
          _ => ()
        }
      }
      None
    }
    _ => None
  }
}

///|
/// Native `zcode_resolve_command_io`. The resolve seam takes a synchronous
/// exists probe while @fs.exists is async, so every candidate path resolve
/// could ask about is probed up front and the closure answers from this
/// cache (candidates from the shared zcode_probe_candidates).
async fn zcode_resolve_command_io(
  config~ : ZcodeConfig,
) -> (String, Array[String]) raise ZcodeError {
  let probed : Map[String, Bool] = Map::from_array([])
  for candidate in zcode_probe_candidates(env=key => @env.get_env_var(key)) {
    probed[candidate] = @fs.exists(candidate) catch { _ => false }
  }
  match
    zcode_resolve_command(config~, env=key => @env.get_env_var(key), exists=path => {
      probed.get(path).unwrap_or(false)
    }) {
    Ok(pair) => pair
    Err(e) => raise e
  }
}

///|
/// Read the v2 credentials and build the provider registry payload.
async fn zcode_registry_io(config~ : ZcodeConfig) -> Json raise ZcodeError {
  let path = zcode_creds_path(config~, env=key => @env.get_env_var(key))
  let raw = @fs.read_file(path) catch {
    e => raise ZcodeCredsUnreadable(detail="cannot read \{path}: \{e}")
  }
  let text = raw.text() catch {
    e => raise ZcodeCredsUnreadable(detail="cannot decode \{path}: \{e}")
  }
  let v2 = @json.parse(text) catch {
    e => raise ZcodeCredsUnreadable(detail="cannot parse \{path}: \{e}")
  }
  match zcode_build_registry(v2, generated_at_ms=@async.now()) {
    Ok(registry) => registry
    Err(message) => raise ZcodeCredsUnreadable(detail=message)
  }
}

///|
/// Default cwd for the tool seam: the real current directory.
async fn zcode_cwd_default() -> String noraise {
  @fs.realpath(".") catch {
    _ => "."
  }
}

///|
/// Native session driver: everything that needs the child runs inside one
/// task group. The group's type parameter is the flow's return type, so the
/// child and the reader task are reclaimed when this returns or raises.
async fn zcode_session_run(
  cmd : (String, Array[String]),
  registry : Json,
  config~ : ZcodeConfig,
  task~ : String,
  cwd~ : String,
  session_id~ : String?,
  mode~ : String,
) -> ZcodeTaskResult raise Error {
  @async.with_task_group(group => {
    zcode_delegated(
      group,
      cmd,
      registry,
      config~,
      task~,
      cwd~,
      session_id~,
      mode~,
    )
  })
}

///|
/// Spawn → bootstrap → create/resume → subscribe → send → event loop under
/// the wall-clock ceiling → teardown (stdin EOF → bounded wait; the task
/// group reclaims a stubborn child via graceful TERM → hard KILL).
async fn zcode_delegated(
  group : @async.TaskGroup[ZcodeTaskResult],
  cmd : (String, Array[String]),
  registry : Json,
  config~ : ZcodeConfig,
  task~ : String,
  cwd~ : String,
  session_id~ : String?,
  mode~ : String,
) -> ZcodeTaskResult raise ZcodeError {
  let (stdin_input, raw_writer) = @process.write_to_process() catch {
    e => raise ZcodeSpawnFailed(detail="zcode: cannot create stdin pipe: \{e}")
  }
  let (reader, stdout_output) = @process.read_from_process() catch {
    e => raise ZcodeSpawnFailed(detail="zcode: cannot create stdout pipe: \{e}")
  }
  let conn : ZcodeConn = {
    pending: Map::from_array([]),
    events: @aqueue.Queue(kind=Unbounded),
    writer: @io.BufferedWriter::new(raw_writer, size=8192),
    raw_writer,
    write_lock: @async.Mutex::Mutex(),
    next_id: 0,
    denial: None,
  }
  let child = @process.spawn(
    group,
    cmd.0,
    cmd.1,
    stdin=stdin_input,
    stdout=stdout_output,
    cancel_handler=@process.graceful_cancel(timeout=5000),
    no_wait=true,
  ) catch {
    e => {
      raw_writer.close()
      reader.close()
      raise ZcodeSpawnFailed(detail="zcode: cannot spawn app-server: \{e}")
    }
  }
  // Reader task: lines → responses / policy replies / events; EOF fails all
  // pending requests and closes the event stream.
  group.spawn_bg(() => {
    let mut open = true
    while open {
      let line : String? = reader.read_until("\n") catch { _ => None }
      match line {
        Some(chunk) => {
          let trimmed = chunk.trim().to_owned()
          if trimmed != "" {
            conn.handle_line(trimmed) catch {
              _ => ()
            }
          }
        }
        None => open = false
      }
      @async.pause() catch {
        _ => ()
      }
    }
    for _, queue in conn.pending {
      queue.put(Err(ZcodeProcessDied(detail="zcode app-server closed stdout"))) catch {
        _ => ()
      }
      queue.close()
    }
    conn.events.close()
  })
  // Bootstrap: push the provider registry built from the v2 credentials.
  let workspace = Json::object(
    Map::from_array([
      ("workspacePath", Json::string(cwd)),
      ("workspaceKey", Json::string(cwd)),
    ]),
  )
  let registry_params = Json::object(
    Map::from_array([("workspace", workspace), ("registry", registry)]),
  )
  match
    conn.request("workspace/updateProviderRegistry", Some(registry_params)) {
    Ok(_) => ()
    Err(ZcodeRpc(code~, message~)) =>
      if message.contains("Model config is missing") {
        raise ZcodeModelConfig(detail="\{message} (rpc code \{code})")
      } else {
        raise ZcodeRpc(code~, message~)
      }
    Err(other) => raise other
  }
  let session_id = match session_id {
    Some(existing) => {
      let resume_params = Json::object(
        Map::from_array([("sessionId", Json::string(existing))]),
      )
      match conn.request("session/resume", Some(resume_params)) {
        Ok(result) =>
          match zcode_session_id_of(result) {
            Some(id) => id
            None => existing
          }
        Err(e) => raise e
      }
    }
    None => {
      let create_params = Json::object(
        Map::from_array([("workspace", workspace), ("mode", Json::string(mode))]),
      )
      match conn.request("session/create", Some(create_params)) {
        Ok(result) =>
          match zcode_session_id_of(result) {
            Some(id) => id
            None =>
              raise ZcodeProtocol(
                detail="session/create response has no session.sessionId",
              )
          }
        Err(e) => raise e
      }
    }
  }
  let subscribe_params = Json::object(
    Map::from_array([
      ("sessionId", Json::string(session_id)),
      ("deliveryKind", Json::string("desktop-continuous")),
      ("includeSnapshot", Json::boolean(true)),
      ("afterSeq", Json::number(0.0)),
    ]),
  )
  match conn.request("session/subscribe", Some(subscribe_params)) {
    Ok(_) => ()
    Err(e) => raise e
  }
  let send_params = Json::object(
    Map::from_array([
      ("sessionId", Json::string(session_id)),
      ("content", Json::string(task)),
    ]),
  )
  match conn.request("session/send", Some(send_params)) {
    Ok(result) =>
      match json_field(result, "accepted") {
        Some(Json::True) => ()
        _ => raise ZcodeProtocol(detail="session/send was not accepted")
      }
    Err(e) => raise e
  }
  // Event loop under the wall-clock ceiling.
  let turn : ZcodeTurn = {
    buffer: "",
    title: "",
    response: "",
    usage: None,
    completed_usage: None,
    failed_message: None,
    terminal: false,
    stream_closed: false,
    cancelled: false,
  }
  let timed : Result[Unit, Error] = Ok(
    @async.with_timeout(
      config.timeout_ms,
      () => zcode_collect_turn(turn, conn),
      error=ZcodeTimeout,
    ),
  ) catch {
    err => Err(err)
  }
  match timed {
    Ok(_) => ()
    Err(err) => raise zcode_raise_typed(err)
  }
  if !turn.terminal {
    if turn.stream_closed {
      raise ZcodeProcessDied(
        detail="zcode app-server exited before the turn reached a terminal event",
      )
    }
    raise ZcodeTimeout
  }
  // Assemble the result, then best-effort teardown that never masks it.
  let mut final_text = if turn.response != "" {
    turn.response
  } else {
    turn.buffer
  }
  let mut stop = "success"
  match turn.failed_message {
    Some(message) => {
      stop = "failed"
      if message != "" {
        final_text = message
      } else if final_text == "" {
        final_text = "zcode turn failed without an error message"
      }
    }
    None => ()
  }
  match conn.denial {
    Some(summary) => {
      stop = "permission_denied"
      final_text = final_text + "\n\n" + summary
    }
    None => ()
  }
  let usage = match turn.completed_usage {
    Some(u) => Some(u)
    None => turn.usage
  }
  let result : ZcodeTaskResult = {
    session_id,
    title: turn.title,
    final_text,
    stop_reason: stop,
    usage,
  }
  // write_line flushes after every line, so the buffer is already empty
  // here; closing stdin is the EOF signal.
  conn.raw_writer.close()
  let _ = @async.with_timeout(5000, () => child.wait()) catch { _ => -1 }
  reader.close()
  result
}

///|
/// Accumulated state of one turn; shared by reference with the collection
/// loop (all mutations happen on the single event-loop thread).
priv struct ZcodeTurn {
  /// Fallback text source when turn.completed carries no response.
  mut buffer : String
  mut title : String
  /// Last session.updated usage sample.
  mut usage : ZcodeUsage?
  /// turn.completed's own usage (preferred over the samples).
  mut completed_usage : ZcodeUsage?
  mut response : String
  mut failed_message : String?
  mut terminal : Bool
  /// The reader closed the event stream before a terminal event.
  mut stream_closed : Bool
  /// The loop was cancelled (wall clock or host) before a terminal event.
  mut cancelled : Bool
}

///|
async fn zcode_collect_turn(turn : ZcodeTurn, conn : ZcodeConn) -> Unit {
  while !turn.terminal && !turn.cancelled {
    let pulled : Result[ZcodeEvent, Error] = Ok(conn.events.get()) catch {
      err => Err(err)
    }
    let next : ZcodeEvent? = match pulled {
      Ok(event) => Some(event)
      Err(err) => {
        if @async.is_cancellation_error(err) {
          turn.cancelled = true
        }
        None
      }
    }
    match next {
      Some(event) =>
        match event {
          TextDelta(delta) => turn.buffer = turn.buffer + delta
          UsageSample(u) => turn.usage = Some(u)
          TitleUpdated(title) => turn.title = title
          TurnCompleted(response~, usage~) => {
            turn.response = response
            turn.completed_usage = usage
            turn.terminal = true
          }
          TurnFailed(message~) => {
            turn.failed_message = Some(message)
            turn.terminal = true
          }
          _ => ()
        }
      None => {
        turn.stream_closed = true
        break
      }
    }
    @async.pause() catch {
      err => if @async.is_cancellation_error(err) { turn.cancelled = true }
    }
  }
}

///|
fn zcode_session_id_of(result : Json) -> String? {
  match json_field(result, "session") {
    Some(session) => json_field_string(session, "sessionId")
    None => None
  }
}
