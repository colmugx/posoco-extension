///|
/// The ordinary test suites never access the network. CI opts into this
/// additional test with MBTX_BOOTSTRAP_TEST=1 to exercise a truly empty home,
/// the official HTTPS installer, the cached second run and real MBTX execution.
async test "managed toolchain bootstraps and executes without preinstalled MoonBit" {
  if @env.get_env_var("MBTX_BOOTSTRAP_TEST") != Some("1") {
    return
  }
  let home = fixture_directory()
  defer fixture_remove(home)
  let runtime = @posoco-ext-mbtx.Runtime(home~, prefer_system=false)
  @async.with_task_group(group => {
    group.add_defer(() => runtime.close())
    let first = runtime.run(
      script_source,
      { "bootstrap": true },
      invocation_id="managed-first",
      timeout_ms=300000,
      handshake_ms=30000,
    )
    assert_true(first.outcome is @protocol.Success(..))
    assert_true(runtime.toolchain_status().contains("Toolchain: managed"))
    let second = runtime.run(
      script_source,
      { "bootstrap": false },
      invocation_id="managed-second",
      timeout_ms=300000,
      handshake_ms=30000,
    )
    assert_true(second.outcome is @protocol.Success(..))
  })
}
