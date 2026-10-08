///|
/// Native defaults use durable storage and Unix-epoch recovery timestamps.
pub fn default_board_runtime(
  event_buffer : Int,
  client_queue_depth? : Int = 256,
) -> BoardRuntime {
  let backend = @backend.BoardBackend::BoardBackend(
    event_buffer~,
    client_queue_depth~,
    store=@store.FileBoardStore::FileBoardStore(root="."),
    now_ms=() => @env.now().reinterpret_as_int64(),
  )
  let server = NativeBoardWebServer::NativeBoardWebServer()
  let opener = NativeBrowserOpener::NativeBrowserOpener()
  BoardRuntime::with_adapters(backend~, server~, opener~)
}
