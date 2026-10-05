///|
/// S1 runtime facade: telemetry remains independent from local control-plane
/// lifecycle. Long-lived server work is owned by a Fuwaroid Supervisor bound
/// to a host TaskGroup through attach(); the durable Board coordinator owns
/// its actor and persistence Supervisor on the same host scope.
pub struct BoardRuntime {
  hub : BoardEventHub
  server : &BoardWebServer
  opener : &BrowserOpener
  coordinator : @coordinator.BoardCoordinator
  gate : @async.Mutex
  mut supervisor : @fuwaroid.Supervisor[Unit]?
  mut server_task : @fuwaroid.SupervisedTask[Unit]?
  mut server_status : BoardServerStatus
}

///|
/// Adapter-injection constructor used by tests and future target backends.
/// A telemetry-serving adapter must receive the same `hub` passed here. The
/// default allocates an independent hub; it cannot discover a server's hub.
/// The coordinator restores from `store` (default: an empty
/// `MemoryBoardStore`), with `now_ms` supplying recovery time (default:
/// deterministic 0). Prefer `default_board_runtime` unless explicitly wiring
/// server and runtime.
pub fn BoardRuntime::with_adapters(
  event_buffer? : Int = 4096,
  hub? : BoardEventHub = BoardEventHub(capacity=event_buffer),
  server~ : &BoardWebServer,
  opener~ : &BrowserOpener,
  store? : &@store.BoardStore = @store.MemoryBoardStore::MemoryBoardStore(),
  now_ms? : () -> Int64 = () => 0L,
) -> BoardRuntime {
  {
    hub,
    server,
    opener,
    coordinator: @coordinator.BoardCoordinator::BoardCoordinator(
      store~,
      now_ms~,
    ),
    gate: @async.Mutex::Mutex(),
    supervisor: None,
    server_task: None,
    server_status: Stopped,
  }
}

///|
/// Bind long-lived runtime workers to a host-owned structured-concurrency
/// scope: the local server Supervisor and the single-writer Board domain
/// coordinator. Repeated attach is idempotent for both; no Agent or Posoco
/// Tasks capability is attached.
pub fn BoardRuntime::attach(
  self : BoardRuntime,
  group : @async.TaskGroup[Unit],
) -> Unit {
  if self.supervisor is None {
    self.supervisor = Some(@fuwaroid.Supervisor(group~))
  }
  self.coordinator.attach(group~)
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
/// Close the current listener. This is idempotent and does not close the
/// Supervisor, so a later /board can bind a fresh random port.
pub async fn BoardRuntime::close_server(self : BoardRuntime) -> Unit {
  self.gate.acquire()
  defer self.gate.release()
  @async.protect_from_cancel(() => self.close_server_locked())
}

///|
/// Final lifecycle teardown: close the listener, close coordinator
/// admission and join its drained loop, then bounded-settle any remaining
/// runtime workers. Idempotent. The whole cleanup is shielded from
/// cancellation, mirroring the gate-protected server paths: a cancelled
/// caller cannot leave a half-open listener or an unjoined coordinator.
pub async fn BoardRuntime::shutdown(self : BoardRuntime) -> Unit {
  @async.protect_from_cancel(() => {
    self.close_server()
    self.coordinator.shutdown()
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
pub fn BoardRuntime::publish_telemetry(
  self : BoardRuntime,
  board_revision~ : Int64,
  kind~ : String,
  scope? : @protocol.BoardEventScope? = None,
  payload~ : Json,
) -> @protocol.BoardWireEvent {
  self.hub.publish(board_revision~, kind~, scope~, payload~)
}

///|
pub fn BoardRuntime::event_history(
  self : BoardRuntime,
) -> Array[@protocol.BoardWireEvent] {
  self.hub.history()
}

///|
pub fn BoardRuntime::current_seq(self : BoardRuntime) -> Int64 {
  self.hub.current_seq()
}
