///|
async test "workflow: activation and every supported playbook use native Skills resources" {
  let fs = PstackFakeFs::new()
  add_bundle_skill(fs)
  let options : @skills.SkillDiscoveryOptions = {
    ..@skills.SkillDiscoveryOptions::default(),
    include_repository: false,
    include_user: false,
  }
  let pstack = Pstack::discover(
    fs,
    cwd="/workspace",
    home="/home/test",
    assets_root="/bundle",
    discovery_options=options,
  ).unwrap()
  assert_true(pstack.catalog().find("poteto-mode").unwrap().body is None)
  match pstack.skills.activate_skill("poteto-mode") {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("Use the engineering workflow"))
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => fail(content)
    _ => fail("PStack SKILL.md should activate")
  }
  for
    name in [
      "investigation", "bug-fix", "feature", "refactoring", "perf-issue", "prototype",
    ] {
    let path = "resources/upstream/skills/poteto-mode/playbooks/" + name + ".md"
    match pstack.skills.read_skill_resource("poteto-mode", path) {
      @posoco.ToolOutcome::Success(content~, ..) =>
        assert_true(content.contains("playbook"))
      @posoco.ToolOutcome::ToolReportedError(content~, ..) => fail(content)
      _ => fail("PStack playbook read should succeed")
    }
  }
  match
    pstack.skills.read_skill_resource(
      "poteto-mode", "resources/posoco-harness.md",
    ) {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("Posoco runtime mapping"))
    _ => fail("Posoco adapter must be readable")
  }
  match pstack.skills.read_skill_resource("poteto-mode", "../outside.md") {
    @posoco.ToolOutcome::ToolReportedError(..) => ()
    _ => fail("resource containment must remain enforced")
  }
}

///|
async test "workflow: discovery rejects a missing required playbook" {
  let fs = PstackFakeFs::new()
  add_bundle_skill(fs)
  ignore(
    fs.files.remove(
      "/bundle/skills/poteto-mode/resources/upstream/skills/poteto-mode/playbooks/feature.md",
    ),
  )
  let options : @skills.SkillDiscoveryOptions = {
    ..@skills.SkillDiscoveryOptions::default(),
    include_repository: false,
    include_user: false,
  }
  assert_true(
    Pstack::discover(
      fs,
      cwd="/workspace",
      home="/home/test",
      assets_root="/bundle",
      discovery_options=options,
    )
    is None,
  )
}

///|
async test "statusbar: every activation channel announces 🥔 Mode and shutdown releases it" {
  let fs = PstackFakeFs::new()
  add_bundle_skill(fs)
  let options : @skills.SkillDiscoveryOptions = {
    ..@skills.SkillDiscoveryOptions::default(),
    include_repository: false,
    include_user: false,
  }
  let system = @posoco.EventSystem()
  let envelopes : Array[@posoco.EventEnvelope] = []
  let _subscription = system
    .subscribe(fn(envelope) { envelopes.push(envelope) })
    .unwrap()
  let publisher = system.publisher(owner="posoco_ext_pstack").unwrap()
  let pstack = Pstack::discover(
    fs,
    cwd="/workspace",
    home="/home/test",
    assets_root="/bundle",
    events=Some(publisher),
    discovery_options=options,
  ).unwrap()
  // Cetas' terminal inlines the activation instructions into the user message.
  let inline = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text(
      "<activated-skill name=\"poteto-mode\">\ninstructions\n</activated-skill>\n\ndo the work",
    ),
  ])
  ignore(pstack.before_model([inline]))
  assert_true(pstack.is_announced())
  assert_eq(envelopes.length(), 1)
  assert_eq(@kit_events.publisher_id(envelopes[0]), Some("posoco_ext_pstack"))
  match @kit_events.status_changed_of(envelopes[0]) {
    Some(@kit_events.Register(segment~, label~, priority~, value~, color~)) => {
      assert_eq(segment, "🥔")
      assert_eq(label, None)
      assert_eq(priority, 5)
      assert_eq(value, Some("Mode"))
      assert_eq(color, Some("success"))
    }
    _ => fail("expected registration")
  }
  pstack.on_shutdown()
  assert_true(!pstack.is_announced())
  assert_eq(envelopes.length(), 2)
  match @kit_events.status_changed_of(envelopes[1]) {
    Some(@kit_events.Unregister(segment~)) => assert_eq(segment, "🥔")
    _ => fail("shutdown must clear status")
  }
}

///|
async test "statusbar: the model-facing activate_skill result also announces 🥔 Mode" {
  let fs = PstackFakeFs::new()
  add_bundle_skill(fs)
  let options : @skills.SkillDiscoveryOptions = {
    ..@skills.SkillDiscoveryOptions::default(),
    include_repository: false,
    include_user: false,
  }
  let pstack = Pstack::discover(
    fs,
    cwd="/workspace",
    home="/home/test",
    assets_root="/bundle",
    discovery_options=options,
    // No publisher and no registered process default: publication is a
    // silent no-op, but the activation fact is still recorded.
  ).unwrap()
  let activation = @posoco.ToolOutcome::Success(
    content="Activated Agent Skill: \"poteto-mode\"",
    structured=Some(
      Json::object({
        "kind": Json::string("agent_skill"),
        "name": Json::string("poteto-mode"),
      }),
    ),
  )
  let tool_message = @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("call_1"),
    tool_name=@posoco.ToolName::unchecked("activate_skill"),
    outcome=activation,
  )
  ignore(pstack.before_model([tool_message]))
  assert_true(pstack.is_announced())
  // An unrelated tool result must not announce.
  let other = Pstack::discover(
    fs,
    cwd="/workspace",
    home="/home/test",
    assets_root="/bundle",
    discovery_options=options,
  ).unwrap()
  ignore(
    other.before_model([
      @posoco.Message::ToolMessage(
        call_id=@posoco.CallId::unchecked("call_2"),
        tool_name=@posoco.ToolName::unchecked("read_file"),
        outcome=@posoco.ToolOutcome::Success(content="ok", structured=None),
      ),
    ]),
  )
  assert_true(!other.is_announced())
}

///|
async test "statusbar: without an injected publisher the process default carries the segment" {
  let fs = PstackFakeFs::new()
  add_bundle_skill(fs)
  let options : @skills.SkillDiscoveryOptions = {
    ..@skills.SkillDiscoveryOptions::default(),
    include_repository: false,
    include_user: false,
  }
  // Hosts assemble the session system as the process default and do not
  // thread it into the skills extension; this is the path they take.
  let system = @posoco.EventSystem()
  @devkit.events_system_register(system)
  let envelopes : Array[@posoco.EventEnvelope] = []
  let _subscription = system
    .subscribe(fn(envelope) { envelopes.push(envelope) })
    .unwrap()
  let pstack = Pstack::discover(
    fs,
    cwd="/workspace",
    home="/home/test",
    assets_root="/bundle",
    discovery_options=options,
  ).unwrap()
  ignore(
    pstack.before_model([
      @posoco.Message::UserMessage(content=[
        @posoco.Content::Text(
          "<activated-skill name=\"poteto-mode\">\ninstructions\n</activated-skill>",
        ),
      ]),
    ]),
  )
  assert_eq(envelopes.length(), 1)
  assert_eq(@kit_events.publisher_id(envelopes[0]), Some("posoco_ext_pstack"))
  match @kit_events.status_changed_of(envelopes[0]) {
    Some(@kit_events.Register(segment~, value~, ..)) => {
      assert_eq(segment, "🥔")
      assert_eq(value, Some("Mode"))
    }
    _ => fail("the process-default channel must carry the 🥔 register op")
  }
}

///|
async test "workflow: embedded descriptor serves playbooks without any files" {
  let fs = PstackFakeFs::new()
  let catalog = @skills.merge_builtin_skills(@skills.SkillCatalog::empty(), [
    Pstack::embedded_descriptor(),
  ])
  let skills = @skills.Skills::from_catalog(
    fs,
    catalog~,
    config=@skills.SkillsConfig::default(),
  ).unwrap()
  let pstack = Pstack::from_skills(skills).unwrap()
  match pstack.skills.activate_skill("poteto-mode") {
    @posoco.ToolOutcome::Success(content~, ..) => {
      assert_true(content.contains("Poteto Mode for Posoco"))
      assert_true(content.contains("Bundled resources"))
    }
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => fail(content)
    _ => fail("embedded PStack SKILL.md should activate")
  }
  let path = "resources/upstream/skills/poteto-mode/playbooks/investigation.md"
  match pstack.skills.read_skill_resource("poteto-mode", path) {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("Investigation requests are read-only"))
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => fail(content)
    _ => fail("embedded playbook read should succeed")
  }
}

///|
async test "statusbar: a shared PStack hides and restores the current session's mode" {
  let catalog = @skills.merge_builtin_skills(@skills.SkillCatalog::empty(), [
    Pstack::embedded_descriptor(),
  ])
  let skills = @skills.Skills::from_catalog(PstackFakeFs::new(), catalog~).unwrap()
  let system = @posoco.EventSystem()
  let envelopes : Array[@posoco.EventEnvelope] = []
  let _subscription = system
    .subscribe(envelope => envelopes.push(envelope))
    .unwrap()
  let publisher = system.publisher(owner="posoco_ext_pstack").unwrap()
  let pstack = Pstack::from_skills(skills, events=Some(publisher)).unwrap()
  let observer = pstack.manifest().observers[0]
  let start = fn(session) {
    observer.on_event(
      Some({
        session_id: @posoco.SessionId::unchecked(session),
        run_id: @posoco.RunId::unchecked("run"),
        turn_id: @posoco.TurnId::unchecked("turn"),
      }),
      @posoco.TurnEvent::TurnStarted,
    )
  }
  let activation = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text(
      "<activated-skill name=\"poteto-mode\">instructions</activated-skill>",
    ),
  ])
  start("a")
  ignore(pstack.before_model([activation]))
  start("a")
  ignore(pstack.before_model([activation]))
  assert_true(pstack.is_announced())
  assert_eq(envelopes.length(), 1)
  assert_eq(envelopes[0].scope.unwrap().session_id.to_string(), "a")

  start("b")
  ignore(pstack.before_model([]))
  assert_false(pstack.is_announced())
  assert_eq(envelopes.length(), 2)
  assert_true(
    @kit_events.status_changed_of(envelopes[1])
    is Some(@kit_events.Unregister(segment="🥔")),
  )
  assert_eq(envelopes[1].scope.unwrap().session_id.to_string(), "b")

  start("a")
  ignore(pstack.before_model([]))
  assert_true(pstack.is_announced())
  assert_eq(envelopes.length(), 3)
  assert_true(
    @kit_events.status_changed_of(envelopes[2])
    is Some(@kit_events.Register(segment="🥔", ..)),
  )
  assert_eq(envelopes[2].scope.unwrap().session_id.to_string(), "a")

  start("b")
  ignore(pstack.before_model([activation]))
  ignore(pstack.before_model([activation]))
  assert_true(pstack.is_announced())
  assert_eq(envelopes.length(), 5)
  assert_true(
    @kit_events.status_changed_of(envelopes[4])
    is Some(@kit_events.Register(segment="🥔", ..)),
  )
  assert_eq(envelopes[4].scope.unwrap().session_id.to_string(), "b")
  pstack.on_shutdown()
  assert_eq(envelopes.length(), 6)
  assert_true(
    @kit_events.status_changed_of(envelopes[5])
    is Some(@kit_events.Unregister(segment="🥔")),
  )
  start("a")
  assert_false(pstack.is_announced())
  assert_eq(envelopes.length(), 6)
}
