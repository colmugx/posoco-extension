///|
test "board extension is inert in s0" {
  let board = BoardExtension::BoardExtension()
  assert_eq(board.extension_id(), "posoco_ext_board")
  let manifest = board.manifest()
  assert_eq(manifest.id, "posoco_ext_board")
  assert_eq(manifest.tools.length(), 0)
  assert_eq(manifest.commands.length(), 0)
  assert_eq(manifest.observers.length(), 0)
  assert_eq(manifest.hooks.length(), 0)
  assert_eq(manifest.lifecycle.length(), 0)
  assert_eq(manifest.requires.length(), 0)
}

///|
test "board config exposes localhost-safe defaults" {
  let config = BoardConfig::BoardConfig()
  assert_false(config.auto_start)
  assert_false(config.auto_open)
  assert_eq(config.bind_host, "127.0.0.1")
  assert_eq(config.event_buffer, 4096)
  assert_eq(config.client_queue_depth, 256)
}
