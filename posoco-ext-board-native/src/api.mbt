///|
using @runtime {
  type BoardRuntime,
  type BoardEndpoint,
  trait BoardWebServer,
  trait BrowserOpener,
}

///|
/// Native standalone composition. Embedded hosts use BoardBackend directly.
///
/// ```mbt check
/// test {
///   let board = @posoco-ext-board-native.board_extension()
///   assert_eq(board.runtime().status(), @runtime.Stopped)
/// }
/// ```
pub fn board_extension(
  config? : @board.BoardConfig = @board.BoardConfig(),
) -> @board.BoardExtension {
  @board.BoardExtension::with_runtime(
    config~,
    runtime=default_board_runtime(
      config.event_buffer,
      client_queue_depth=config.client_queue_depth,
    ),
  )
}
