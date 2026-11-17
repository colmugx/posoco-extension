///|
/// A native Posoco extension that owns one Skills runtime, ships the
/// PStack workflows as file-backed resources, and exposes its slash command.
pub struct Pstack {
  skills : @skills.Skills
  events : @posoco.Events?
  mut mode_active : Bool
}

///|
/// Low-level adapter for a Skills runtime that already contains poteto-mode:
/// file-backed discovery (Pstack::discover) and hosts registering the
/// Pstack::embedded_descriptor both land here.
pub fn Pstack::from_skills(
  skills : @skills.Skills,
  events~ : @posoco.Events? = None,
) -> Pstack? {
  match skills.catalog().find("poteto-mode") {
    Some(_) => Some({ skills, events, mode_active: false, })
    None => None
  }
}

///|
/// Built-in descriptor for hosts that ship the workflow inside their binary:
/// the instructions and every playbook travel as inline resources, so no
/// assets directory or install step is required.
pub fn Pstack::embedded_descriptor() -> @skills.SkillDescriptor {
  @skills.SkillDescriptor::builtin(
    name="poteto-mode",
    description="Run PStack's task-specific engineering playbooks on Posoco. Select investigation, bug fix, feature, refactoring, performance, or prototype workflows and verify the result.",
    body=embedded_skill_body(),
    resources=embedded_skill_resources(),
  )
}

///|
/// The installed PStack assets directory holds SKILL.md, original playbooks,
/// principles, and optional Kind presets.
fn asset_path(root : String, suffix : String) -> String {
  if root.has_suffix("/") {
    root + suffix
  } else {
    root + "/" + suffix
  }
}

///|
/// Add an optional PStack asset skill root after the host's existing roots.
/// Retained for hosts that intentionally want file-based overrides.
pub fn pstack_discovery_options(
  assets_root : String,
  base~ : @skills.SkillDiscoveryOptions = @skills.SkillDiscoveryOptions::default(),
) -> @skills.SkillDiscoveryOptions {
  if assets_root.trim().is_empty() {
    return base
  }
  let roots = base.extra_roots.copy()
  let path = asset_path(assets_root, "skills")
  if !roots.contains(path) {
    roots.push(path)
  }
  { ..base, extra_roots: roots, }
}

///|
/// Discover the actual PStack workflow through Posoco's file-backed Skills.
/// Inline built-ins cannot expose playbooks through read_skill_resource.
pub async fn Pstack::discover(
  fs : &@workspace.WorkspaceFs,
  cwd~ : String,
  home~ : String,
  assets_root~ : String,
  discovery_options~ : @skills.SkillDiscoveryOptions = @skills.SkillDiscoveryOptions::default(),
  config~ : @skills.SkillsConfig = @skills.SkillsConfig::default(),
  events~ : @posoco.Events? = None,
) -> Pstack? noraise {
  if assets_root.trim().is_empty() {
    return None
  }
  let skill_dir = asset_path(assets_root, "skills/poteto-mode")
  let required = [
    "SKILL.md", "resources/posoco-harness.md", "resources/upstream/skills/poteto-mode/SKILL.md",
    "resources/upstream/skills/poteto-mode/playbooks/investigation.md", "resources/upstream/skills/poteto-mode/playbooks/bug-fix.md",
    "resources/upstream/skills/poteto-mode/playbooks/feature.md", "resources/upstream/skills/poteto-mode/playbooks/refactoring.md",
    "resources/upstream/skills/poteto-mode/playbooks/perf-issue.md", "resources/upstream/skills/poteto-mode/playbooks/prototype.md",
  ]
  for path in required {
    let exists = fs.exists(asset_path(skill_dir, path)) catch { _ => false }
    if !exists {
      return None
    }
  }
  let options = pstack_discovery_options(assets_root, base=discovery_options)
  match
    @skills.Skills::discover(
      fs,
      cwd~,
      home~,
      discovery_options=options,
      config~,
    ) {
    Some(skills) => Pstack::from_skills(skills, events~)
    None => None
  }
}

///|
/// Access the exact catalog used for model-facing skill activation.
pub fn Pstack::catalog(self : Pstack) -> @skills.SkillCatalog {
  self.skills.catalog()
}

///|
/// Whether this Agent session has activated Poteto Mode.
pub fn Pstack::is_mode_active(self : Pstack) -> Bool {
  self.mode_active
}

///|
/// Publish the status segment consumed by posoco-ext-statusbar. The key is
/// the potato glyph so Cetas-style rendering displays exactly "🥔 Mode On".
fn Pstack::publish_mode_status(self : Pstack, active : Bool) -> Unit {
  match self.events {
    Some(events) =>
      if active {
        ignore(
          events.publish(
            @kit_events.StatusChanged(
              @kit_events.Register(
                segment="🥔",
                label=None,
                priority=5,
                value=Some("Mode On"),
                color=Some("success"),
              ),
            ),
          ),
        )
      } else {
        ignore(
          events.publish(
            @kit_events.StatusChanged(@kit_events.Unregister(segment="🥔")),
          ),
        )
      }
    None => ()
  }
}

///|
/// Idempotent session status transition. Status is session-scoped and is
/// toggled by /poteto-mode and cleared by Agent shutdown.
fn Pstack::set_mode_active(self : Pstack, active : Bool) -> Unit {
  if self.mode_active == active {
    return
  }
  self.mode_active = active
  self.publish_mode_status(active)
}

///|
/// Load bundled Kind presets through the same WorkspaceFs used for skills.
/// Pass these as extra to KindCatalog::load(home~, cwd~, extra~).
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
/// Reuse Skills' model-facing tools and prompt contributor. PStack adds a
/// toggle command and a shutdown hook that clears its status segment.
pub impl @posoco.Extension for Pstack with fn manifest(self : Pstack) -> @posoco.ExtensionManifest {
  let inner = @posoco.Extension::manifest(self.skills)
  let commands : Array[&@posoco.CommandPort] = inner.commands.copy()
  commands.push(self)
  let lifecycle : Array[&@posoco.Lifecycle] = [self]
  @posoco.ExtensionManifest(
    id="posoco_ext_pstack",
    tools=inner.tools,
    commands~,
    lifecycle~,
    prompt_contributors=inner.prompt_contributors,
  )
}

///|
pub impl @posoco.Extension for Pstack with fn extension_id(_self : Pstack) -> String {
  "posoco_ext_pstack"
}

///|
fn poteto_mode_command_def() -> @posoco.CommandDef {
  @posoco.CommandDef::{
    id: "poteto-mode",
    label: "Poteto Mode",
    description: "Toggle PStack's rigorous engineering method for this session",
    category: "workflow",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: None,
    icon: Some("🥔"),
    visible: true,
    metadata: None,
  }
}

///|
pub impl @posoco.CommandPort for Pstack with fn commands(_self : Pstack) -> Array[
  @posoco.CommandDef,
] {
  [poteto_mode_command_def()]
}

///|
/// Reuse Skills' activation result. Publish the status indicator only after
/// activation succeeds; failures never produce a false "Mode On".
pub impl @posoco.CommandPort for Pstack with fn invoke(
  self : Pstack,
  id : String,
  _args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  match id {
    "poteto-mode" =>
      if self.mode_active {
        self.set_mode_active(false)
        @posoco.CommandOutcome::Success(
          feedback="🥔 Poteto Mode Off",
          structured=None,
          ui_hint=Some(@posoco.UiHint::None),
        )
      } else {
        let outcome = @posoco.CommandPort::invoke(
          self.skills,
          "skills",
          Json::object({
            "action": Json::string("activate"),
            "name": Json::string("poteto-mode"),
          }),
        )
        match outcome {
          @posoco.CommandOutcome::Success(..) => self.set_mode_active(true)
          _ => ()
        }
        outcome
      }
    other => raise @posoco.CommandError::NotFound(other)
  }
}

///|
pub impl @posoco.Lifecycle for Pstack with fn on_shutdown(self : Pstack) -> Unit {
  self.set_mode_active(false)
}

///|
pub extend Pstack with @posoco.Extension::{extension_id, manifest}

///|
pub extend Pstack with @posoco.CommandPort::{commands, invoke}

///|
pub extend Pstack with @posoco.Lifecycle::{on_compose, on_start, on_shutdown}
