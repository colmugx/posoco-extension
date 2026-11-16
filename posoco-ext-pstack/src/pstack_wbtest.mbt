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
  fs.add_file(
    "/bundle/skills/poteto-mode/SKILL.md",
    #|---
    #|name: poteto-mode
    #|description: PStack engineering workflow entry point
    #|---
    #|# Poteto Mode
    #|
    #|Use the engineering workflow and load the relevant playbook.
  )
}

///|
async test "discover: PStack bundle becomes a native skill catalog" {
  let fs = PstackFakeFs()
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
    discovery_options~,
  )
  match pstack {
    None => fail("expected the bundled poteto-mode skill to be discovered")
    Some(extension) => {
      assert_true(extension.catalog().find("poteto-mode") is Some(_))
      assert_eq(extension.extension_id(), "posoco_ext_pstack")
    }
  }
}

///|
async test "discover: missing bundle entry is not registered" {
  let fs = PstackFakeFs()
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
      discovery_options~,
    ) is None,
  )
}

///|
async test "manifest: native PStack extension forwards Skills tools and prompt" {
  let fs = PstackFakeFs()
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
    discovery_options~,
  ).unwrap()
  let manifest = @posoco.Extension::manifest(pstack)
  assert_eq(manifest.id, "posoco_ext_pstack")
  assert_eq(manifest.tools.length(), 1)
  assert_eq(manifest.prompt_contributors.length(), 1)
  assert_eq(manifest.commands.length(), 2)
  let tools = @posoco.ToolProvider::list_tools(manifest.tools[0])
  assert_eq(
    tools.map(t => t.name.to_string()),
    ["activate_skill", "read_skill_resource", "skill_search"],
  )
  let prompt = @posoco.SystemPromptContributor::system_prompt(
    manifest.prompt_contributors[0],
  )
  assert_true(prompt.contains("poteto-mode"))
  assert_true(prompt.contains("activate_skill"))
  assert_eq(
    @posoco.CommandPort::commands(pstack).map(c => c.id),
    ["poteto-mode"],
  )
}

///|
async test "command: poteto-mode returns the structured skill activation envelope" {
  let fs = PstackFakeFs()
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
    discovery_options~,
  ).unwrap()
  match
    @posoco.CommandPort::invoke(
      pstack,
      "poteto-mode",
      Json::object(Map([])),
    ) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_eq(feedback, "activated skill: poteto-mode")
      match structured {
        Some(payload) => {
          let rendered = payload.stringify()
          assert_true(rendered.contains("agent_skill_activation"))
          assert_true(rendered.contains("PStack engineering workflow"))
        }
        None => fail("activation result must include structured instructions")
      }
    }
    @posoco.CommandOutcome::Failure(reason~) => fail(reason)
    @posoco.CommandOutcome::NeedsInput(prompt~) => fail(prompt)
  }
}

///|
async test "kinds: packaged presets parse into native KindSpec values" {
  let fs = PstackFakeFs()
  fs.add_file(
    "/bundle/agents/poteto-agent.md",
    #|---
    #|name: poteto-agent
    #|description: General PStack engineering agent
    #|mode: workspace_write
    #|---
    #|Work on the assigned engineering task.
  )
  fs.add_file(
    "/bundle/agents/comment-sicko.md",
    #|---
    #|name: comment-sicko
    #|description: Adversarial code reviewer
    #|mode: readonly
    #|---
    #|Review code and report concrete findings.
  )
  let specs = Pstack::load_kinds(fs, "/bundle").unwrap()
  assert_eq(specs.length(), 2)
  assert_eq(specs[0].name, "poteto-agent")
  assert_eq(specs[1].name, "comment-sicko")
  let catalog = @kind.KindCatalog::with_entries(specs).unwrap()
  assert_true(catalog.get("poteto-agent") is Some(_))
  assert_true(catalog.get("comment-sicko") is Some(_))
}

///|
async test "kinds: missing preset fails loudly instead of silently dropping a role" {
  let fs = PstackFakeFs()
  fs.add_file(
    "/bundle/agents/poteto-agent.md",
    #|---
    #|name: poteto-agent
    #|description: General PStack engineering agent
    #|---
    #|Work on the assigned engineering task.
  )
  assert_true(Pstack::load_kinds(fs, "/bundle") is Err(_))
}
