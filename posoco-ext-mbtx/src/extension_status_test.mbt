///|
/// Toolchain status is runtime-local diagnostics, not an EventSystem
/// publication. This test intentionally has no devkit or kit-events imports.
async test "mbtx initializes its toolchain once and exposes local status" {
  let manager = @posoco-ext-mbtx.ToolchainManager()
  assert_true(manager.status().contains("MBTX: uninitialized"))

  let first = manager.ensure_ready()
  assert_eq(first.origin, @posoco-ext-mbtx.ToolchainOrigin::System)
  let ready = manager.status()
  assert_true(ready.contains("MBTX: ready"))
  assert_true(ready.contains("Toolchain: system"))
  assert_true(ready.contains("Version:"))

  let second = manager.ensure_ready()
  assert_eq(second.origin, first.origin)
  assert_eq(manager.status(), ready)
}

///|
test "mbtx extension registers status command without eager provisioning" {
  let ext = @posoco-ext-mbtx.MbtxExtension()
  let manifest = ext.manifest()
  assert_eq(manifest.id, "posoco_ext_mbtx")
  assert_eq(manifest.commands.length(), 1)
  let commands = manifest.commands[0].commands()
  assert_eq(commands.length(), 1)
  assert_eq(commands[0].id, "mbtx")
}
