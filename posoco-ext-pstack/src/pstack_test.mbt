///|
test "pstack adds one bundled skill root after the host roots" {
  let base : @skills.SkillDiscoveryOptions = {
    ..@skills.SkillDiscoveryOptions::default(),
    extra_roots: ["/host/skills"],
  }
  let options = pstack_discovery_options("/installed/pstack/assets", base~)
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
  let options = pstack_discovery_options("/installed/pstack/assets", base~)
  assert_eq(options.extra_roots, ["/installed/pstack/assets/skills"])
}

///|
test "pstack exposes the poteto-mode command" {
  let command = poteto_mode_command_def()
  assert_eq(command.id, "poteto-mode")
  assert_eq(command.category, "skills")
}
