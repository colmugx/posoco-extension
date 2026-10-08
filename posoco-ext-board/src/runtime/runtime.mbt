///|
/// S3C0 runtime facade: presentation lifecycle only. The headless
/// `BoardBackend` privately owns the telemetry hub, the durable coordinator
/// and the command clock; the runtime owns the local server, the browser
/// opener and their supervised workers. Long-lived server work is owned by
/// a Fuwaroid Supervisor bound to a host TaskGroup through attach(); the
/// backend joins the same host scope.
pub struct BoardRuntime {
  priv backend_ : @backend.BoardBackend
  server : &BoardWebServer
  opener : &BrowserOpener
  priv gate : @async.Mutex
  priv mut supervisor : @fuwaroid.Supervisor[Unit]?
  priv mut server_task : @fuwaroid.SupervisedTask[Unit]?
  priv mut server_status : BoardServerStatus
}

///|
/// Adapter-injection constructor: one explicitly built backend plus the
/// presentation adapters. The runtime never inspects or replaces the
/// backend; it installs it on the server through the `set_backend` seam
/// before binding the control plane.
pub fn BoardRuntime::with_adapters(
  backend~ : @backend.BoardBackend,
  server~ : &BoardWebServer,
  opener~ : &BrowserOpener,
) -> BoardRuntime {
  {
    backend_: backend,
    server,
    opener,
    gate: @async.Mutex::Mutex(),
    supervisor: None,
    server_task: None,
    server_status: Stopped,
  }
}

///|
/// The headless backend owned by this runtime: commands, snapshots and
/// subscriptions work with no presentation adapter at all.
pub fn BoardRuntime::backend(self : BoardRuntime) -> @backend.BoardBackend {
  self.backend_
}

///|
/// Bind long-lived workers to a host-owned structured-concurrency scope:
/// the local server Supervisor and the backend's single-writer durable
/// coordinator. Repeated attach is idempotent for both; no Agent or Posoco
/// Tasks capability is attached.
pub fn BoardRuntime::attach(
  self : BoardRuntime,
  group : @async.TaskGroup[Unit],
) -> Unit {
  if self.supervisor is None {
    self.supervisor = Some(@fuwaroid.Supervisor(group~))
  }
  self.backend_.attach(group)
}

///|
async fn BoardRuntime::settle_server_task(self : BoardRuntime) -> Unit {
  match (self.supervisor, self.server_task) {
    (Some(supervisor), Some(task)) => {
      let tasks = [task]
      let _ = supervisor.cancel_and_wait(
        tasks=tasks.clamped_view(),
        timeout_ms=5000,
      )
      self.server_task = None
    }
    _ => self.server_task = None
  }
}

///|
/// Assumes gate is held and cancellation is protected.
async fn BoardRuntime::ensure_server_locked(
  self : BoardRuntime,
) -> Result[BoardEndpoint, String] {
  match self.server_status {
    Running(endpoint) if self.server.is_alive() => return Ok(endpoint)
    Running(_) | Failed(_) => {
      self.server.close()
      self.settle_server_task()
      self.server_status = Stopped
    }
    Starting | Stopping =>
      return Err("board control plane is in a transitional state")
    Stopped => ()
  }
  let supervisor = match self.supervisor {
    Some(value) => value
    None =>
      return Err(
        "board runtime is not attached to a host TaskGroup; call board.attach(group) before /board",
      )
  }
  self.server_status = Starting
  // The single presentation seam: the server answers snapshots, commands
  // and stream frames through the owned backend.
  self.server.set_backend(self.backend_)
  let endpoint = match self.server.bind() {
    Ok(value) => value
    Err(error) => {
      self.server_status = Failed(error)
      return Err(error)
    }
  }
  let server = self.server
  let spawned = supervisor.spawn(
    async fn() { let _ = server.run() },
    label="board-http",
  )
  match spawned {
    Err(_) => {
      self.server.close()
      self.server_status = Failed("board server worker refused by supervisor")
      Err("board server worker refused by supervisor")
    }
    Ok(task) => {
      self.server_task = Some(task)
      self.server_status = Running(endpoint)
      Ok(endpoint)
    }
  }
}

///|
/// Idempotently start the local control plane. Concurrent callers serialize
/// through one async gate; only one listener can be admitted.
pub async fn BoardRuntime::ensure_server(
  self : BoardRuntime,
) -> Result[BoardEndpoint, String] {
  self.gate.acquire()
  defer self.gate.release()
  @async.protect_from_cancel(() => self.ensure_server_locked())
}

///|
/// Ensure the control plane exists, then ask the platform opener to focus it.
/// The returned endpoint is token-free.
pub async fn BoardRuntime::open_board(
  self : BoardRuntime,
) -> Result[BoardEndpoint, String] {
  let endpoint = match self.ensure_server() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let url = match self.server.browser_url() {
    Some(value) => value
    None => return Err("board server did not expose a browser bootstrap URL")
  }
  match self.opener.open(url) {
    Ok(_) => Ok(endpoint)
    Err(error) => Err(error)
  }
}

///|
async fn BoardRuntime::close_server_locked(self : BoardRuntime) -> Unit {
  match self.server_status {
    Stopped => return
    _ => ()
  }
  self.server_status = Stopping
  self.server.close()
  self.settle_server_task()
  self.server_status = Stopped
}

///|
/// Close the current listener. This is idempotent, never shuts the backend
/// down, and does not close the Supervisor, so a later /board can bind a
/// fresh random port while headless service continues.
pub async fn BoardRuntime::close_server(self : BoardRuntime) -> Unit {
  self.gate.acquire()
  defer self.gate.release()
  @async.protect_from_cancel(() => self.close_server_locked())
}

///|
/// Final lifecycle teardown: close the presentation first, then the
/// backend's coordinator admission and drained loop, then bounded-settle
/// any remaining runtime workers. Idempotent. The whole cleanup is shielded
/// from cancellation, mirroring the gate-protected server paths: a
/// cancelled caller cannot leave a half-open listener or an unjoined
/// coordinator.
pub async fn BoardRuntime::shutdown(self : BoardRuntime) -> Unit {
  @async.protect_from_cancel(() => {
    self.close_server()
    self.backend_.shutdown()
    match self.supervisor {
      Some(supervisor) => {
        let _ = supervisor.shutdown(timeout_ms=5000)
        self.supervisor = None
      }
      None => ()
    }
  })
}

///|
/// Status never exposes the instance token. A worker that exited unexpectedly
/// is projected as Failed even if the last durable lifecycle state was
/// Running.
pub fn BoardRuntime::status(self : BoardRuntime) -> BoardServerStatus {
  match self.server_status {
    Running(_) if !self.server.is_alive() =>
      match self.server.last_error() {
        Some(error) => Failed(error)
        None => Stopped
      }
    other => other
  }
}

///|
/// Compatibility delegates to the owned backend. Prefer `backend()` for new
/// code; these keep the runtime facade usable without reaching for the
/// backend first.

///|
pub async fn BoardRuntime::handle_command(
  self : BoardRuntime,
  wire : @protocol.BoardClientCommand,
) -> @protocol.BoardCommandResult {
  self.backend_.handle_command(wire)
}

///|
pub async fn BoardRuntime::bootstrap_snapshot(
  self : BoardRuntime,
) -> Result[@protocol.BoardSnapshot, String] {
  self.backend_.bootstrap_snapshot()
}

///|
pub fn BoardRuntime::publish_telemetry(
  self : BoardRuntime,
  board_revision~ : Int64,
  kind~ : String,
  scope? : @protocol.BoardEventScope? = None,
  payload~ : Json,
) -> @protocol.BoardWireEvent {
  self.backend_.publish_telemetry(board_revision~, kind~, scope~, payload~)
}

///|
pub fn BoardRuntime::event_history(
  self : BoardRuntime,
) -> Array[@protocol.BoardWireEvent] {
  self.backend_.event_history()
}

///|
pub fn BoardRuntime::current_seq(self : BoardRuntime) -> Int64 {
  self.backend_.current_seq()
}
