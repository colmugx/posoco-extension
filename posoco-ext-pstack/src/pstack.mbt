///|
/// A native Posoco extension that owns one Skills runtime and exposes the
/// PStack entry command. Compose this OR the standalone Skills extension,
/// never both: both expose the same activation and resource tools.
pub struct Pstack {
  skills : @skills.Skills
}

///|
/// Keep one Skills runtime for both the model-facing tools and slash commands.
/// A manually supplied catalog must contain poteto-mode.
pub fn Pstack::from_skills(skills : @skills.Skills) -> Pstack? {
  match skills.catalog().find("poteto-mode") {
    Some(_) => Some({ skills, })
    None => None
  }
}

///|
/// The installation directory of the package's assets, supplied by the host.
/// Assets include `skills/poteto-mode/SKILL.md` and `agents/*.md`.
fn asset_path(root : String, suffix : String) -> String {
  if root.has_suffix("/") {
    root + suffix
  } else {
    root + "/" + suffix
  }
}

///|
/// Add PStack to normal repository/user skills discovery, at the lowest
/// precedence, without replacing any of the caller's trusted roots.
pub fn pstack_discovery_options(
  assets_root : String,
  base~ : @skills.SkillDiscoveryOptions = @skills.SkillDiscoveryOptions::default(),
) -> @skills.SkillDiscoveryOptions {
  let roots = base.extra_roots.copy()
  let path = asset_path(assets_root, "skills")
  if !roots.contains(path) {
    roots.push(path)
  }
  { ..base, extra_roots: roots, }
}

///|
/// Build the native adapter from a packaged assets root. No duplicate Skills
/// instance should be added to the Agent after composing this Pstack value.
///
/// Project and user skills take precedence over the bundled version; this is
/// intentional and follows the existing SkillDiscovery precedence rules.
pub async fn Pstack::discover(
  fs : &@workspace.WorkspaceFs,
  cwd~ : String,
  home~ : String,
  assets_root~ : String,
  discovery_options~ : @skills.SkillDiscoveryOptions = @skills.SkillDiscoveryOptions::default(),
  config~ : @skills.SkillsConfig = @skills.SkillsConfig::default(),
) -> Pstack? noraise {
  if assets_root.trim().is_empty() {
    return None
  }
  let entry = asset_path(assets_root, "skills/poteto-mode/SKILL.md")
  let present = fs.exists(entry) catch { _ => false }
  if !present {
    return None
  }
  let options = pstack_discovery_options(assets_root, base=discovery_options)
  match @skills.Skills::discover(
    fs,
    cwd~,
    home~,
    discovery_options=options,
    config~,
  ) {
    Some(skills) => Pstack::from_skills(skills)
    None => None
  }
}

///|
/// Access the exact catalog used for model-facing skill activation.
pub fn Pstack::catalog(self : Pstack) -> @skills.SkillCatalog {
  self.skills.catalog()
}

///|
/// Load bundled Kind presets through the same WorkspaceFs used for skills.
/// Pass these as `extra` to KindCatalog::load(home~, cwd~, extra~).
/// The Kind loader retains project-over-user-over-extra precedence.
pub async fn Pstack::load_kinds(
  fs : &@workspace.WorkspaceFs,
  assets_root : String,
) -> Result[Array[@kind.KindSpec], String] noraise {
  if assets_root.trim().is_empty() {
    return Err("PStack assets root must not be empty")
  }
  let kinds : Array[@kind.KindSpec] = []
  for name in ["poteto-agent", "comment-sicko"] {
    let path = asset_path(assets_root, "agents/" + name + ".md")
    let content = fs.read_file(path) catch {
      _ => return Err("PStack kind missing or unreadable: " + name)
    }
    let spec = @kind.parse_kind_file(content) catch {
      _ => return Err("Invalid PStack kind file: " + name)
    }
    if spec.name != name {
      return Err("PStack kind name differs from asset path: " + name)
    }
    kinds.push(spec)
  }
  Ok(kinds)
}

///|
/// Reuse the original Skills port implementations so its resource confinement,
/// tool schemas, catalog prompt, and activation semantics remain native.
pub impl @posoco.Extension for Pstack with fn manifest(
  self : Pstack,
) -> @posoco.ExtensionManifest {
  let inner = @posoco.Extension::manifest(self.skills)
  let commands : Array[&@posoco.CommandPort] = inner.commands.copy()
  commands.push(self)
  @posoco.ExtensionManifest(
    id="posoco_ext_pstack",
    tools=inner.tools,
    commands~,
    prompt_contributors=inner.prompt_contributors,
  )
}

///|
pub impl @posoco.Extension for Pstack with fn extension_id(
  _self : Pstack,
) -> String {
  "posoco_ext_pstack"
}

///|
fn poteto_mode_command_def() -> @posoco.CommandDef {
  @posoco.CommandDef::{
    id: "poteto-mode",
    label: "Poteto mode",
    description: "Activate PStack's engineering workflow for this task",
    category: "skills",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: true,
    metadata: None,
  }
}

///|
pub impl @posoco.CommandPort for Pstack with fn commands(
  _self : Pstack,
) -> Array[@posoco.CommandDef] {
  [poteto_mode_command_def()]
}

///|
/// Reuse Skills' own command activation result, including its structured
/// `agent_skill_activation` envelope. No synthetic tool call is created.
pub impl @posoco.CommandPort for Pstack with fn invoke(
  self : Pstack,
  id : String,
  _args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  if id != "poteto-mode" {
    raise @posoco.CommandError::NotFound(id)
  }
  @posoco.CommandPort::invoke(
    self.skills,
    "skills",
    Json::object({
      "action": Json::string("activate"),
      "name": Json::string("poteto-mode"),
    }),
  )
}

///|
pub extend Pstack with @posoco.Extension::{extension_id, manifest}

///|
pub extend Pstack with @posoco.CommandPort::{commands, invoke}
