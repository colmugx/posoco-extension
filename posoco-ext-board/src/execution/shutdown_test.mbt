///|
struct SlowCleanupAdapter {
  entered : @aqueue.Queue[Unit]
  cleaning : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
}

///|
impl @execution.BoardExecutionAdapter for SlowCleanupAdapter with fn ready(
  _self,
) {
  true
}

///|
impl @execution.BoardExecutionAdapter for SlowCleanupAdapter with fn run(
  self,
  request,
  start,
) {
  assert_true(
    start({ session_id: request.session_id, run_id: "run", turn_id: "turn", }),
  )
  self.entered.put(())
  let completed = @async.handle_cancellation(() => @async.sleep(60000))
  @async.protect_from_cancel(() => {
    self.cleaning.put(())
    self.release.get()
  })
  if completed is None {
    @execution.Cancelled
  } else {
    @execution.Completed
  }
}

///|
async test "bounded shutdown retains ownership and cannot claim Cancelled before driver cleanup confirms termination" {
  @async.with_task_group(group => {
    let backend = prepared_board(group)
    let driver : SlowCleanupAdapter = {
      entered: @aqueue.Queue(kind=Unbounded),
      cleaning: @aqueue.Queue(kind=Unbounded),
      release: @aqueue.Queue(kind=Unbounded),
    }
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter=driver,
      store=journal(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let handle = owner.execute(request()).unwrap()
    driver.entered.get()
    assert_false(owner.shutdown(timeout_ms=30))
    driver.cleaning.get()
    assert_eq(backend.state().unwrap().attempts[0].status, @domain.Running)
    assert_true(owner.execute(request()) is Err(@execution.Closed))
    driver.release.put(())
    assert_eq(handle.wait().outcome, Some(@execution.Cancelled))
    assert_eq(backend.state().unwrap().attempts[0].status, @domain.Cancelled)
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}

///|
struct PresentationServer {
  mut installed : Bool
  mut alive : Bool
  closed : @aqueue.Queue[Unit]
}

///|
impl @runtime.BoardWebServer for PresentationServer with fn set_backend(
  self,
  _backend,
) {
  self.installed = true
}

///|
impl @runtime.BoardWebServer for PresentationServer with fn bind(self) {
  assert_true(self.installed)
  self.alive = true
  Ok(@runtime.BoardEndpoint::{ host: "127.0.0.1", port: 12345, })
}

///|
impl @runtime.BoardWebServer for PresentationServer with fn run(self) {
  self.closed.get()
  Ok(())
}

///|
impl @runtime.BoardWebServer for PresentationServer with fn close(self) {
  self.alive = false
  ignore(self.closed.try_put(()) catch { _ => false })
}

///|
impl @runtime.BoardWebServer for PresentationServer with fn is_alive(self) {
  self.alive
}

///|
impl @runtime.BoardWebServer for PresentationServer with fn browser_url(_self) {
  None
}

///|
impl @runtime.BoardWebServer for PresentationServer with fn last_error(_self) {
  None
}

///|
struct NoBrowser {}

///|
impl @runtime.BrowserOpener for NoBrowser with fn open(_self, _url) {
  Err("not used")
}

///|
async test "closing standalone presentation does not cancel headless owned execution" {
  @async.with_task_group(group => {
    let backend = prepared_board(group)
    let server : PresentationServer = {
      installed: false,
      alive: false,
      closed: @aqueue.Queue(kind=Unbounded),
    }
    let runtime = @runtime.BoardRuntime::with_adapters(backend~, server~, opener=NoBrowser::{
    })
    runtime.attach(group)
    assert_true(runtime.ensure_server() is Ok(_))
    let adapter = controlled(block=true)
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=journal(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let handle = owner.execute(request()).unwrap()
    adapter.entered.get()
    runtime.close_server()
    assert_false(server.alive)
    assert_eq(backend.state().unwrap().attempts[0].status, @domain.Running)
    assert_eq(owner.bindings()[0].phase, @execution.Running)
    adapter.release.put(())
    assert_eq(handle.wait().outcome, Some(@execution.Completed))
    assert_true(owner.shutdown())
    runtime.shutdown()
  })
}
