///|
/// File-backed discovery over the real committed assets tree. This runs on
/// the native target only: it needs a host filesystem (mirroring
/// posoco-ext-workspace's convention for IO-backed tests), while the fake-fs
/// tests in pstack_wbtest.mbt cover the same parser path on every target.

///|
/// The committed assets tree registers 57 of the 58 upstream skills: every
/// upstream directory except the excluded make-bot-ui (pure Cursor
/// Automations/plugin UI machinery, scripts/bundle-config.mjs) — the three
/// hand adapters plus 54 generated wrappers — and discovery must parse each
/// wrapper's `disable-model-invocation` frontmatter into the descriptor flag.
#cfg(target="native")
async test "discover: the real assets tree registers wrappers with upstream invocation flags" {
  let fs = @workspace.NativeWorkspaceFs()
  let options : @skills.SkillDiscoveryOptions = {
    ..@skills.SkillDiscoveryOptions::default(),
    include_repository: false,
    include_user: false,
  }
  let pstack = Pstack::discover(
    fs,
    cwd=".",
    home=".",
    assets_root="assets",
    discovery_options=options,
  ).unwrap()
  let catalog = pstack.catalog()
  assert_eq(catalog.skills.length(), 57)
  assert_true(catalog.find("tdd").unwrap().user_invoked_only)
  assert_true(catalog.find("architect").unwrap().user_invoked_only)
  assert_true(catalog.find("swarm").unwrap().user_invoked_only)
  assert_true(catalog.find("unslop").unwrap().user_invoked_only)
  // setup-pstack is the one upstream skill without the frontmatter flag.
  assert_false(catalog.find("setup-pstack").unwrap().user_invoked_only)
  // The hand adapters align with their flagged upstream copies.
  assert_true(catalog.find("poteto-mode").unwrap().user_invoked_only)
  assert_true(catalog.find("poteto-help").unwrap().user_invoked_only)
  assert_true(catalog.find("no-comments").unwrap().user_invoked_only)
  // The excluded skill is not registered in any form.
  assert_true(catalog.find("make-bot-ui") is None)
}
