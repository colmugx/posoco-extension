///|
struct PstackFakeFs {
  files : Map[String, String]
  dirs : Map[String, Array[String]]
}

///|
fn PstackFakeFs::new() -> PstackFakeFs {
  { files: Map([]), dirs: Map([]), }
}

///|
fn PstackFakeFs::add_file(
  self : PstackFakeFs,
  path : String,
  content : String,
) -> Unit {
  self.files.set(path, content)
}

///|
fn PstackFakeFs::add_dir(
  self : PstackFakeFs,
  path : String,
  entries : Array[String],
) -> Unit {
  self.dirs.set(path, entries)
}

///|
pub impl @workspace.WorkspaceFs for PstackFakeFs with fn exists(
  self : PstackFakeFs,
  path : String,
) -> Bool {
  self.files.contains(path) || self.dirs.contains(path)
}

///|
pub impl @workspace.WorkspaceFs for PstackFakeFs with fn kind(
  self : PstackFakeFs,
  path : String,
  follow_symlink~ : Bool,
) -> @workspace.WorkspaceFileKind {
  ignore(follow_symlink)
  if self.files.contains(path) {
    @workspace.WorkspaceFileKind::File
  } else if self.dirs.contains(path) {
    @workspace.WorkspaceFileKind::Dir
  } else {
    @workspace.WorkspaceFileKind::Other
  }
}

///|
pub impl @workspace.WorkspaceFs for PstackFakeFs with fn read_file(
  self : PstackFakeFs,
  path : String,
) -> String raise @workspace.WorkspaceFsError {
  match self.files.get(path) {
    Some(value) => value
    None =>
      raise @workspace.WorkspaceFsError::WorkspaceFsError("missing: " + path)
  }
}

///|
pub impl @workspace.WorkspaceFs for PstackFakeFs with fn readdir(
  self : PstackFakeFs,
  path : String,
  include_hidden~ : Bool,
) -> Array[String] raise @workspace.WorkspaceFsError {
  match self.dirs.get(path) {
    Some(entries) => {
      let result : Array[String] = []
      for entry in entries {
        if include_hidden || !entry.has_prefix(".") {
          result.push(entry)
        }
      }
      result
    }
    None =>
      raise @workspace.WorkspaceFsError::WorkspaceFsError("missing: " + path)
  }
}

///|
pub impl @workspace.WorkspaceFs for PstackFakeFs with fn realpath(
  _self : PstackFakeFs,
  path : String,
) -> String {
  path
}

///|
pub impl @workspace.WorkspaceFs for PstackFakeFs with fn write_file(
  _self : PstackFakeFs,
  _path : String,
  _content : String,
) -> Unit {
  ()
}

///|
pub impl @workspace.WorkspaceFs for PstackFakeFs with fn write_file_atomic(
  _self : PstackFakeFs,
  _path : String,
  _content : String,
) -> Unit {
  ()
}

///|
pub impl @workspace.WorkspaceFs for PstackFakeFs with fn remove(
  _self : PstackFakeFs,
  _path : String,
) -> Unit {
  ()
}

///|
pub impl @workspace.WorkspaceFs for PstackFakeFs with fn rename(
  _self : PstackFakeFs,
  _from : String,
  _to : String,
  replace~ : Bool,
) -> Unit {
  ignore(replace)
}

///|
pub impl @workspace.WorkspaceFs for PstackFakeFs with fn mkdir(
  _self : PstackFakeFs,
  _path : String,
  recursive~ : Bool,
) -> Unit {
  ignore(recursive)
}

///|
pub impl @workspace.WorkspaceFs for PstackFakeFs with fn walk(
  _self : PstackFakeFs,
  _root : String,
  _callback : async (String, Array[String]) -> Unit,
) -> Unit {
  ()
}

///|
fn add_bundle_skill(fs : PstackFakeFs) -> Unit {
  fs.add_dir("/bundle/skills", ["poteto-mode"])
  fs.add_dir("/bundle/skills/poteto-mode", ["SKILL.md"])
  let skill_md =
    #|---
    #|name: poteto-mode
    #|description: PStack engineering workflow entry point
    #|---
    #|# Poteto Mode
    #|
    #|Use the engineering workflow and load the relevant playbook.
  fs.add_file("/bundle/skills/poteto-mode/SKILL.md", skill_md)
  fs.add_dir("/bundle/skills/poteto-mode", ["SKILL.md", "resources"])
  fs.add_dir("/bundle/skills/poteto-mode/resources", [
    "posoco-harness.md", "upstream",
  ])
  fs.add_file(
    "/bundle/skills/poteto-mode/resources/posoco-harness.md", "# Posoco runtime mapping",
  )
  fs.add_dir("/bundle/skills/poteto-mode/resources/upstream", ["skills"])
  fs.add_dir("/bundle/skills/poteto-mode/resources/upstream/skills", [
    "poteto-mode",
  ])
  fs.add_dir(
    "/bundle/skills/poteto-mode/resources/upstream/skills/poteto-mode",
    ["SKILL.md", "playbooks"],
  )
  fs.add_file(
    "/bundle/skills/poteto-mode/resources/upstream/skills/poteto-mode/SKILL.md",
    "# Upstream Poteto Mode",
  )
  let playbooks = [
    "investigation", "bug-fix", "feature", "refactoring", "perf-issue", "prototype",
  ]
  fs.add_dir(
    "/bundle/skills/poteto-mode/resources/upstream/skills/poteto-mode/playbooks",
    playbooks.map(name => name + ".md"),
  )
  for name in playbooks {
    fs.add_file(
      "/bundle/skills/poteto-mode/resources/upstream/skills/poteto-mode/playbooks/" +
      name +
      ".md",
      "# " + name + " playbook: Trace, change, verify.",
    )
  }
}

///|
/// A bundle plus one generated-style wrapper skill: frontmatter carries the
/// upstream `disable-model-invocation: true` flag and no resources of its
/// own; its instructions route back through poteto-mode's upstream tree.
fn add_bundle_wrapper_skill(fs : PstackFakeFs) -> Unit {
  add_bundle_skill(fs)
  fs.add_dir("/bundle/skills", ["poteto-mode", "architect"])
  fs.add_dir("/bundle/skills/architect", ["SKILL.md"])
  let skill_md =
    #|---
    #|name: architect
    #|description: "Plan before building: turn the task into a reviewed design."
    #|disable-model-invocation: true
    #|---
    #|# architect (PStack upstream skill)
    #|
    #|Read the full upstream instructions with read_skill_resource(name="poteto-mode", path="resources/upstream/skills/architect/SKILL.md").
  fs.add_file("/bundle/skills/architect/SKILL.md", skill_md)
}

///|
async test "discover: PStack bundle becomes a native skill catalog" {
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
  )
  match pstack {
    None => fail("expected the bundled poteto-mode skill to be discovered")
    Some(extension) => {
      let skill = extension.catalog().find("poteto-mode").unwrap()
      assert_true(skill.body is None)
      assert_eq(skill.skill_md_path, "/bundle/skills/poteto-mode/SKILL.md")
      assert_eq(extension.extension_id(), "posoco_ext_pstack")
    }
  }
}

///|
async test "discover: disable-model-invocation frontmatter marks a file-backed skill user-invoked-only" {
  let fs = PstackFakeFs::new()
  add_bundle_wrapper_skill(fs)
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
  let catalog = pstack.catalog()
  // The wrapper's frontmatter flag lands on the discovered descriptor.
  assert_true(catalog.find("architect").unwrap().user_invoked_only)
  // The unflagged adapter stays model-invocable, and poteto-mode still keys
  // the Pstack runtime regardless of wrapper flags.
  assert_false(catalog.find("poteto-mode").unwrap().user_invoked_only)
  // File-backed wrappers own no resources: upstream content is read through
  // poteto-mode's resource tree, as their instructions say.
  assert_true(catalog.find("architect").unwrap().resources.is_empty())
}

///|
async test "discover: missing bundle is rejected rather than silently using a summary" {
  let fs = PstackFakeFs::new()
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
async test "manifest: native PStack extension forwards Skills tools and prompt" {
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
  let manifest = @posoco.Extension::manifest(pstack)
  assert_eq(manifest.id, "posoco_ext_pstack")
  assert_eq(manifest.tools.length(), 1)
  assert_eq(manifest.prompt_contributors.length(), 1)
  // Skills' own `skills` command, and no pstack-owned command: the workflow is
  // entered with the `$poteto-mode` mention the Skills layer already handles.
  assert_eq(manifest.commands.length(), 1)
  assert_eq(manifest.commands[0].commands().map(c => c.id), ["skills"])
  // Skills' explicit-mention hook must survive the manifest merge, otherwise
  // `$name` activation never reaches the model.
  assert_eq(manifest.hooks.length(), 2)
  let tools = @posoco.ToolProvider::list_tools(manifest.tools[0])
  assert_eq(tools.map(t => t.name.to_string()), [
    "activate_skill", "read_skill_resource", "skill_search",
  ])
  let prompt = @posoco.SystemPromptContributor::system_prompt(
    manifest.prompt_contributors[0],
  )
  assert_true(prompt.contains("poteto-mode"))
  assert_true(prompt.contains("activate_skill"))
}

///|
async test "status: a poteto-mode activation announces 🥔 Mode exactly once" {
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
    discovery_options=options,
    events=Some(publisher),
  ).unwrap()
  // Hosts whose terminal does not inline the instructions deliver `$name`
  // activation as the Skills explicit-mention envelope.
  let activation_envelope = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text(
      "<cetas-context type=\"skill_activation\" trust=\"false\" source=\"skill:poteto-mode\" invocation=\"explicit\">\nbody\n</cetas-context>",
    ),
  ])
  ignore(pstack.before_model([activation_envelope]))
  assert_true(pstack.is_announced())
  assert_eq(envelopes.length(), 1)
  match @kit_events.status_changed_of(envelopes[0]) {
    Some(@kit_events.Register(segment~, label~, priority~, value~, color~)) => {
      assert_eq(segment, "🥔")
      assert_eq(label, None)
      assert_eq(priority, 5)
      assert_eq(value, Some("Mode"))
      assert_eq(color, Some("success"))
    }
    _ => fail("expected the 🥔 segment to be registered")
  }
  // A plain request announces nothing, and the second activation must not
  // duplicate the segment.
  ignore(
    pstack.before_model([
      @posoco.Message::UserMessage(content=[
        @posoco.Content::Text("plain request"),
      ]),
    ]),
  )
  ignore(pstack.before_model([activation_envelope]))
  assert_eq(envelopes.length(), 1)
  pstack.on_shutdown()
  assert_true(!pstack.is_announced())
  assert_eq(envelopes.length(), 2)
  match @kit_events.status_changed_of(envelopes[1]) {
    Some(@kit_events.Unregister(segment~)) => assert_eq(segment, "🥔")
    _ => fail("shutdown must release the 🥔 segment")
  }
}

///|
async test "kinds: packaged presets parse into native KindSpec values" {
  let fs = PstackFakeFs::new()
  let poteto_agent =
    #|---
    #|name: poteto-agent
    #|description: General PStack engineering agent
    #|mode: workspace_write
    #|---
    #|Work on the assigned engineering task.
  let comment_sicko =
    #|---
    #|name: comment-sicko
    #|description: Adversarial code reviewer
    #|mode: readonly
    #|---
    #|Review code and report concrete findings.
  fs.add_file("/bundle/agents/poteto-agent.md", poteto_agent)
  fs.add_file("/bundle/agents/comment-sicko.md", comment_sicko)
  let specs = Pstack::load_kinds(fs, "/bundle").unwrap()
  assert_eq(specs.length(), 2)
  assert_eq(specs[0].name, "poteto-agent")
  assert_eq(specs[1].name, "comment-sicko")
  let catalog = @kind.KindCatalog::with_entries(specs)
  assert_true(catalog.get("poteto-agent") is Some(_))
  assert_true(catalog.get("comment-sicko") is Some(_))
}

///|
async test "kinds: missing preset fails loudly instead of silently dropping a role" {
  let fs = PstackFakeFs::new()
  let poteto_agent =
    #|---
    #|name: poteto-agent
    #|description: General PStack engineering agent
    #|---
    #|Work on the assigned engineering task.
  fs.add_file("/bundle/agents/poteto-agent.md", poteto_agent)
  assert_true(Pstack::load_kinds(fs, "/bundle") is Err(_))
}

///|
test "embedded: descriptors carry every bundled skill without any files" {
  let descriptors = Pstack::embedded_descriptors()
  // 58 upstream skills minus the make-bot-ui exclusion (pure Cursor
  // Automations/plugin UI machinery with no portable workflow prose,
  // scripts/bundle-config.mjs) = 57 registered: the three hand adapters in
  // their fixed registration order, then the generated wrappers.
  assert_eq(descriptors.length(), 57)
  assert_eq(descriptors[0].name, "poteto-mode")
  assert_eq(descriptors[1].name, "poteto-help")
  assert_eq(descriptors[2].name, "no-comments")
  for name in ["tdd", "architect", "swarm", "unslop", "setup-pstack"] {
    let mut found = false
    for descriptor in descriptors {
      if descriptor.name == name {
        found = true
      }
    }
    assert_true(found)
  }
  // The first entry must stay identical to the single-skill descriptor hosts
  // already register, so adding skills cannot change poteto-mode's shape.
  let single = Pstack::embedded_descriptor()
  assert_eq(descriptors[0].name, single.name)
  assert_eq(descriptors[0].description, single.description)
  assert_eq(descriptors[0].body, single.body)
  assert_eq(descriptors[0].resources, single.resources)
  assert_eq(descriptors[0].user_invoked_only, single.user_invoked_only)
  // Each descriptor serves exactly the bundle the standalone accessors read,
  // and its flag matches the bundle metadata generated from frontmatter.
  let frontmatter : Map[String, String] = Map::from_array(
    embedded_skill_frontmatter(),
  )
  let flags = embedded_skill_user_invoked_only()
  for descriptor in descriptors {
    assert_eq(descriptor.description, frontmatter.get(descriptor.name).unwrap())
    assert_eq(descriptor.user_invoked_only, flags.get(descriptor.name).unwrap())
    assert_eq(
      descriptor.body.unwrap(),
      embedded_skill_bodies().get(descriptor.name).unwrap(),
    )
    assert_eq(
      descriptor.resources,
      embedded_skill_resource_sets().get(descriptor.name).unwrap(),
    )
  }
}

///|
test "embedded: invocation flags follow upstream frontmatter" {
  let flags : Map[String, Bool] = Map::from_array(
    Pstack::embedded_descriptors().map(fn(descriptor) {
      (descriptor.name, descriptor.user_invoked_only)
    }),
  )
  // Upstream marks tdd user-invoked-only; setup-pstack is the one upstream
  // skill without the frontmatter flag and stays model-invocable; the three
  // hand adapters align with their (flagged) upstream copies.
  assert_true(flags.get("tdd").unwrap())
  assert_false(flags.get("setup-pstack").unwrap())
  assert_true(flags.get("poteto-mode").unwrap())
  assert_true(flags.get("poteto-help").unwrap())
  assert_true(flags.get("no-comments").unwrap())
  // Exactly setup-pstack is model-invocable; every other registered skill
  // carries disable-model-invocation: true, and the excluded make-bot-ui is
  // absent entirely.
  let mut user_only = 0
  let mut model_invocable = 0
  for descriptor in Pstack::embedded_descriptors() {
    if descriptor.user_invoked_only {
      user_only = user_only + 1
    } else {
      model_invocable = model_invocable + 1
      assert_eq(descriptor.name, "setup-pstack")
    }
  }
  assert_eq(user_only, 56)
  assert_eq(model_invocable, 1)
  assert_true(flags.get("make-bot-ui") is None)
}

///|
test "embedded: the Skills prompt offers setup-pstack but never a user-invoked-only skill" {
  let fs = PstackFakeFs::new()
  let catalog : @skills.SkillCatalog = {
    skills: Pstack::embedded_descriptors(),
    diagnostics: [],
  }
  let skills = @skills.Skills::from_catalog(fs, catalog~).unwrap()
  let manifest = @posoco.Extension::manifest(skills)
  assert_eq(manifest.prompt_contributors.length(), 1)
  let prompt = @posoco.SystemPromptContributor::system_prompt(
    manifest.prompt_contributors[0],
  )
  // The only model-invocable skill is offered; the 56 user-invoked-only
  // skills (including tdd and the poteto-mode entry point itself) stay out of
  // the startup catalog while remaining activatable through explicit
  // invocation.
  assert_true(prompt.contains("setup-pstack"))
  assert_false(prompt.contains("tdd"))
  assert_false(prompt.contains("poteto-mode"))
  assert_false(prompt.contains("unslop"))
}

///|
test "embedded: agent presets parse into kinds without any files" {
  let specs = Pstack::embedded_kinds().unwrap()
  assert_eq(specs.map(s => s.name), ["poteto-agent", "comment-sicko"])
  // poteto-agent delegates writes; comment-sicko only reviews and reports.
  assert_true(specs[0].mode is @permission.PermissionMode::WorkspaceWrite)
  assert_true(specs[1].mode is @permission.PermissionMode::ReadOnly)
  let catalog = @kind.KindCatalog::with_entries(specs)
  assert_true(catalog.get("poteto-agent") is Some(_))
  assert_true(catalog.get("comment-sicko") is Some(_))
}

///|
test "embedded: unknown frontmatter keys like is_background stay ignored" {
  // Upstream copies of these presets carry keys Posoco has no equivalent for;
  // parsing must tolerate them rather than reject the preset.
  let source =
    #|---
    #|name: probe
    #|description: Tolerates upstream-only keys
    #|mode: readonly
    #|is_background: true
    #|---
    #|Report only.
  let spec = @kind.parse_kind_file(source)
  assert_eq(spec.name, "probe")
  assert_true(spec.mode is @permission.PermissionMode::ReadOnly)
}

///|
pub extend PstackFakeFs with @workspace.WorkspaceFs::{
  write_file_atomic,
  walk,
  realpath,
  mkdir,
  write_file,
  kind,
  remove,
  rename,
  exists,
  read_file,
  readdir,
}
