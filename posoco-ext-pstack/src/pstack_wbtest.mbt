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
