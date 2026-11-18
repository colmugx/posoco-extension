///|
/// A native Posoco extension that owns one Skills runtime, ships the
/// PStack workflows as file-backed resources, and mirrors a successful
/// poteto-mode activation onto the session status bar.
pub struct Pstack {
  skills : @skills.Skills
  events : @posoco.Events?
  /// Set once `before_model` observes this session's poteto-mode activation;
  /// the status segment is session-scoped and published exactly once.
  mut announced : Bool
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
    Some(_) => Some({ skills, events, announced: false, })
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
/// Whether this Agent session has already reported poteto-mode activation.
pub fn Pstack::is_announced(self : Pstack) -> Bool {
  self.announced
}

///|
/// Publish one status op on the session channel: the publisher injected at
/// composition, else the process default system the host registers at
/// assembly (the same fallback `posoco-ext-statusbar` uses). A missing or
/// closed channel is a rendering gap, never an error.
fn Pstack::publish_status(self : Pstack, op : @kit_events.StatusOp) -> Unit {
  let event : @posoco.Event = @kit_events.StatusChanged(op)
  match self.events {
    Some(events) => ignore(events.publish(event))
    None =>
      match @devkit.events_system_default() {
        Some(system) =>
          match system.publisher(owner="posoco_ext_pstack") {
            Ok(publisher) => ignore(publisher.publish(event))
            Err(_) => ()
          }
        None => ()
      }
  }
}

///|
/// Trailing messages inspected for activation evidence. Every evidence shape
/// lands next to the turn's input, so a bounded tail keeps the per-step cost
/// flat for sessions that never activate the workflow.
const ACTIVATION_SCAN_DEPTH : Int32 = 12

///|
const POTETO_SKILL_NAME : String = "poteto-mode"

///|
/// Activation-instruction tags written by the harnesses we ship:
/// `posoco-ext-skills`' explicit-mention envelope (`$name` in hosts without a
/// terminal-side injection) and Cetas' terminal `$name` prompt (the shell
/// inlines the same instructions). Both carry the activation itself, so either
/// tag is proof the skill is in this session's context.
const EXPLICIT_ENVELOPE_TAG : String = "<cetas-context type=\"skill_activation\""

///|
const EXPLICIT_ENVELOPE_SOURCE : String = "source=\"skill:poteto-mode\""

///|
const HOST_INJECTED_TAG : String = "<activated-skill name=\"poteto-mode\">"

///|
/// The model-facing `activate_skill` result carries the activated skill's
/// name and kind in `structured`, so detection needs no prose matching.
fn structured_activation_is_poteto(outcome : @posoco.ToolOutcome) -> Bool {
  match outcome {
    @posoco.ToolOutcome::Success(structured=Some(Json::Object(fields)), ..) => {
      let field = fn(key : String) -> String {
        match fields.get(key) {
          Some(Json::String(value)) => value
          _ => ""
        }
      }
      let kind = field("kind")
      field("name") == POTETO_SKILL_NAME &&
      (kind == "builtin_agent_skill" || kind == "agent_skill")
    }
    _ => false
  }
}

///|
fn message_announces_poteto(
  message : @posoco.Message,
  activate_tool_name : String,
) -> Bool {
  match message {
    @posoco.Message::ToolMessage(tool_name~, outcome~, ..) =>
      tool_name.to_string() == activate_tool_name &&
      structured_activation_is_poteto(outcome)
    @posoco.Message::UserMessage(content~) => {
      let mut text = ""
      for block in content {
        match block {
          @posoco.Content::Text(value) => text = text + value
          _ => ()
        }
      }
      text.contains(HOST_INJECTED_TAG) ||
      (
        text.contains(EXPLICIT_ENVELOPE_TAG) &&
        text.contains(EXPLICIT_ENVELOPE_SOURCE)
      )
    }
    _ => false
  }
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
/// Reuse Skills' model-facing tools, prompt contributor and explicit-mention
/// hook, then append this extension's activation observer. Without the inner
/// hooks `$name` activation never reaches the model in hosts whose terminal
/// does not inline the instructions itself.
pub impl @posoco.Extension for Pstack with fn manifest(self : Pstack) -> @posoco.ExtensionManifest {
  let inner = @posoco.Extension::manifest(self.skills)
  let hooks : Array[&@posoco.PipelineHook] = inner.hooks.copy()
  hooks.push(self)
  let lifecycle : Array[&@posoco.Lifecycle] = [self]
  @posoco.ExtensionManifest(
    id="posoco_ext_pstack",
    tools=inner.tools,
    hooks~,
    commands=inner.commands,
    lifecycle~,
    prompt_contributors=inner.prompt_contributors,
  )
}

///|
pub impl @posoco.Extension for Pstack with fn extension_id(_self : Pstack) -> String {
  "posoco_ext_pstack"
}

///|
/// Report the workflow on the status bar as soon as the session's transcript
/// proves poteto-mode was activated. The skill instructions arrive through the
/// Skills extension; this hook only mirrors that fact as `🥔 Mode`, and only
/// once per session.
pub impl @posoco.PipelineHook for Pstack with fn before_model(
  self : Pstack,
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] {
  if self.announced {
    return messages
  }
  let activate_tool_name = self.skills.config().activate_tool_name
  let floor = if messages.length() > ACTIVATION_SCAN_DEPTH {
    messages.length() - ACTIVATION_SCAN_DEPTH
  } else {
    0
  }
  let mut index = messages.length()
  while index > floor {
    index = index - 1
    if message_announces_poteto(messages[index], activate_tool_name) {
      self.announced = true
      self.publish_status(
        @kit_events.Register(
          segment="🥔",
          label=None,
          priority=5,
          value=Some("Mode"),
          color=Some("success"),
        ),
      )
      break
    }
  }
  messages
}

///|
/// The status segment is session-scoped: release it when the Agent shuts down.
pub impl @posoco.Lifecycle for Pstack with fn on_shutdown(self : Pstack) -> Unit {
  if self.announced {
    self.announced = false
    self.publish_status(@kit_events.Unregister(segment="🥔"))
  }
}

///|
pub extend Pstack with @posoco.Extension::{extension_id, manifest}

///|
pub extend Pstack with @posoco.PipelineHook::{before_model}

///|
pub extend Pstack with @posoco.Lifecycle::{on_compose, on_start, on_shutdown}
