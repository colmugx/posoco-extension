///|
test "pstack adds one bundled skill root after the host roots" {
  let base : @skills.SkillDiscoveryOptions = {
    ..@skills.SkillDiscoveryOptions::default(),
    extra_roots: ["/host/skills"],
  }
  let options = @posoco-ext-pstack.pstack_discovery_options(
    "/installed/pstack/assets",
    base~,
  )
  assert_eq(
    options.extra_roots,
    ["/host/skills", "/installed/pstack/assets/skills"],
  )
  assert_true(options.include_repository)
  assert_true(options.include_user)
}

///|
test "pstack does not duplicate an already configured skill root" {
  let base : @skills.SkillDiscoveryOptions = {
    ..@skills.SkillDiscoveryOptions::default(),
    extra_roots: ["/installed/pstack/assets/skills"],
  }
  let options = @posoco-ext-pstack.pstack_discovery_options(
    "/installed/pstack/assets",
    base~,
  )
  assert_eq(options.extra_roots, ["/installed/pstack/assets/skills"])
}
