///|
//// A native Posoco extension that owns one Skills runtime, ships the
//// poteto-mode Skill as an inline built-in, and exposes its slash commands.
pub struct Pstack {
  skills : @skills.Skills
  events : @posoco.Events?
  mut mode_active : Bool
}

///|
//// The core PStack methodology is compiled into the extension. Activation
//// does not depend on locating Markdown files in the installed package.
fn pstack_methodology() -> String {
  let body =
    #|# Poteto Mode — rigorous engineering
    #|
    #|Use this workflow for engineering work that needs careful reasoning,
    #|small changes, and evidence that the result works. Quality is the goal;
    #|throughput without correctness is not.
    #|
    #|## Operating contract
    #|
    #|1. **Start with the goal.** Restate the user's intended outcome, the
    #|   problem being solved, and the smallest change that can meet it.
    #|   Proceed on reversible work; do not ask for permission to investigate.
    #|2. **Observe before asking.** Read the relevant code, run the smallest
    #|   useful experiment, reproduce behavior, or inspect real output before
    #|   asking a question. Ask only for a genuine product choice that evidence
    #|   cannot settle.
    #|3. **Model the domain before coding.** Identify the state, invariants,
    #|   ownership, and data shape. Prefer a clear state machine, typed model,
    #|   or registry over scattered flags and repeated assumptions.
    #|4. **Trace before changing.** Read the affected subsystem and its callers.
    #|   Understand the existing contract and regression history. Do not make
    #|   speculative defensive changes without evidence.
    #|5. **Keep the change small.** Delete dead weight before adding layers.
    #|   Fix causes rather than symptoms. Avoid abstractions with one caller.
    #|6. **Make progress verifiable.** Split substantial work into ordered
    #|   units. Each unit ends with a check. State the next checkpoint and what
    #|   evidence will prove it.
    #|7. **Verify the real behavior.** Run tests and checks on the affected
    #|   surface. Reproduce the original scenario after a fix. Review the final
    #|   diff. Compilation alone is not proof of behavior.
    #|8. **Own the result.** Inspect delegated work yourself. Report what ran,
    #|   what passed, what did not, and what remains. Never claim an unrun check.
    #|
    #|## Choose the narrowest workflow
    #|
    #|### Investigation
    #|For a read-only question: trace the relevant code path, collect evidence,
    #|separate facts from inference, and answer with the key concepts, locations,
    #|mechanism, and gotchas. Do not create a PR or modify code unless the user
    #|also asked for a change.
    #|
    #|### Bug fix
    #|1. Reproduce the defect on the same surface where it occurs.
    #|2. Form competing hypotheses and eliminate them with runtime evidence.
    #|3. Confirm the surviving root-cause mechanism before editing.
    #|4. Add or identify a regression test that fails before the fix.
    #|5. Ship the smallest cause-level change.
    #|6. Re-run the original reproduction and relevant regression suite.
    #|A workaround that merely hides the symptom is not a fix.
    #|
    #|### Feature
    #|1. Trace the affected subsystem and define its contract.
    #|2. Compare viable designs when the data shape or boundary is unclear.
    #|3. Write a short plan with blocking steps, independent workstreams,
    #|   shared mutable state, and the smallest safe decomposition.
    #|4. Delegate only genuinely independent work. Give each subagent a
    #|   standalone goal, scope, constraints, and verification criteria.
    #|5. Integrate deliberately; review every diff and serialize shared writes.
    #|6. Verify behavior, edge cases, and the user-visible surface.
    #|
    #|### Refactor
    #|Establish the current behavior and tests first. State the invariant that
    #|must not change. Migrate callers in a coherent sequence, remove obsolete
    #|paths rather than carrying compatibility layers indefinitely, and prove
    #|behavioral equivalence with relevant tests.
    #|
    #|### Review
    #|Read the diff and surrounding code independently. Prioritize correctness,
    #|security, data loss, concurrency, compatibility, and missing tests.
    #|Report actionable findings with file/line references and impact. Do not
    #|invent issues to fill a quota; distinguish blockers from suggestions.
    #|
    #|## Engineering principles
    #|
    #|- **Laziness protocol:** prefer the smallest sufficient change; subtract
    #|  before adding.
    #|- **Foundational thinking:** choose the right data model and ownership
    #|  boundaries before writing branches.
    #|- **Attack the premise:** after repeated failed fixes, test the shared
    #|  assumption instead of trying another variation of it.
    #|- **Boundary discipline:** validate untrusted input at system boundaries;
    #|  keep internal business logic typed and direct.
    #|- **Type discipline:** make invalid states difficult to represent.
    #|- **Idempotence:** commands and lifecycle operations should converge
    #|  safely when retried.
    #|- **Reader load:** reduce layers, hidden state, and unnecessary comments.
    #|- **Outcome orientation:** converge on the intended architecture rather
    #|  than preserving throwaway migration states.
    #|- **Separate shared writes:** avoid concurrent mutation of the same file,
    #|  branch, key, or object; serialize only when an invariant requires it.
    #|- **Prove it works:** test observable behavior, not private implementation.
    #|- **Explain measurements:** establish baselines and rule out confounders
    #|  before reporting performance or quality numbers.
    #|- **Encode repeated lessons:** when an instruction recurs, prefer a test,
    #|  type, lint, or runtime invariant over another paragraph.
    #|
    #|## Delegation and autonomy
    #|
    #|Use the native Posoco subagent capability for independent work. Keep
    #|the parent responsible for task framing, integration, and review. Use
    #|configured model slots; never copy model identifiers from another agent
    #|harness. A child brief must include goal, scope, verification, and report
    #|format. Do not parallelize work that shares mutable files.
    #|
    #|Proceed with reversible investigation and implementation. Pause before
    #|irreversible actions such as deployment, deleting user data, force-pushing
    #|a shared branch, or sending an external/customer-facing message unless
    #|the user has explicitly authorized that action.
    #|
    #|## Posoco runtime
    #|
    #|Use the tools and lifecycle provided by the composed Posoco Agent.
    #|Use native Skills activation/resource tools, subagent, planning, todo,
    #|question, filesystem, and shell tools when they are present. Do not emit
    #|Cursor or Claude Code tool syntax, slash commands, model slugs, hooks, or
    #|automation assumptions as if Posoco supported them.
    #|
    #|Reply in the user's language. Be concise but include the goal, decisions,
    #|verification evidence, limitations, and the next concrete step.
  body
}

///|
//// The primary PStack skill is a true inline SkillDescriptor. Discovered
//// project/user Skills may intentionally override it by name.
fn pstack_builtin_skills() -> Array[@skills.SkillDescriptor] {
  [
    @skills.SkillDescriptor::builtin(
      name="poteto-mode",
      description="PStack's rigorous engineering method: investigation, feature design and implementation, root-cause bug fixing, refactoring, code review, deliberate delegation, and evidence-based verification. Use when the user invokes /poteto-mode or asks for careful engineering work.",
      body=pstack_methodology(),
    ),
  ]
}

///|
//// Low-level adapter for a Skills runtime that already contains poteto-mode.
/// Prefer Pstack::builtin or Pstack::discover so the primary method is
//// registered automatically.
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
//// Construct PStack with its primary Skill compiled into the extension.
/// No assets path or file-system discovery is needed for poteto-mode.
pub fn Pstack::builtin(
  fs : &@workspace.WorkspaceFs,
  events~ : @posoco.Events? = None,
  config~ : @skills.SkillsConfig = @skills.SkillsConfig::default(),
) -> Result[Pstack, String] {
  let catalog = @skills.merge_builtin_skills(
    @skills.SkillCatalog::empty(),
    pstack_builtin_skills(),
  )
  match @skills.Skills::from_catalog(fs, catalog~, config~) {
    Ok(skills) => Ok({ skills, events, mode_active: false, })
    Err(reason) => Err(reason)
  }
}

///|
//// The installation directory of optional package assets. It is only needed
//// for Kind preset files and the legacy file-discovery constructor.
fn asset_path(root : String, suffix : String) -> String {
  if root.has_suffix("/") {
    root + suffix
  } else {
    root + "/" + suffix
  }
}

///|
//// Add an optional PStack asset skill root after the host's existing roots.
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
//// Discover project/user Skills and merge the inline PStack method into the
//// same catalog. A same-name project/user Skill intentionally overrides it.
pub async fn Pstack::discover(
  fs : &@workspace.WorkspaceFs,
  cwd~ : String,
  home~ : String,
  assets_root~ : String = "",
  discovery_options~ : @skills.SkillDiscoveryOptions = @skills.SkillDiscoveryOptions::default(),
  config~ : @skills.SkillsConfig = @skills.SkillsConfig::default(),
  events~ : @posoco.Events? = None,
) -> Pstack? noraise {
  let options = pstack_discovery_options(assets_root, base=discovery_options)
  match
    @skills.Skills::discover(
      fs,
      cwd~,
      home~,
      discovery_options=options,
      config~,
    ) {
    Some(discovered) => {
      let catalog = @skills.merge_builtin_skills(
        discovered.catalog(),
        pstack_builtin_skills(),
      )
      match @skills.Skills::from_catalog(fs, catalog~, config~) {
        Ok(skills) => Pstack::from_skills(skills, events~)
        Err(_) => None
      }
    }
    None => None
  }
}

///|
//// Access the exact catalog used for model-facing skill activation.
pub fn Pstack::catalog(self : Pstack) -> @skills.SkillCatalog {
  self.skills.catalog()
}

///|
//// Whether this Agent session has activated Poteto Mode.
pub fn Pstack::is_mode_active(self : Pstack) -> Bool {
  self.mode_active
}

///|
//// Publish the status segment consumed by posoco-ext-statusbar. The key is
//// the potato glyph so Cetas-style rendering displays exactly "🥔 Mode On".
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
            @kit_events.StatusChanged(
              @kit_events.Unregister(segment="🥔"),
            ),
          ),
        )
      }
    None => ()
  }
}

///|
//// Idempotent session status transition. Status is session-scoped and is
//// cleared by /poteto-mode-off or Agent shutdown.
fn Pstack::set_mode_active(self : Pstack, active : Bool) -> Unit {
  if self.mode_active == active {
    return
  }
  self.mode_active = active
  self.publish_mode_status(active)
}

///|
//// Load bundled Kind presets through the same WorkspaceFs used for skills.
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
//// Reuse Skills' model-facing tools and prompt contributor. PStack adds its
//// commands and a shutdown hook that clears its status segment.
pub impl @posoco.Extension for Pstack with fn manifest(
  self : Pstack,
) -> @posoco.ExtensionManifest {
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
pub impl @posoco.Extension for Pstack with fn extension_id(
  _self : Pstack,
) -> String {
  "posoco_ext_pstack"
}

///|
fn poteto_mode_command_def() -> @posoco.CommandDef {
  @posoco.CommandDef::{
    id: "poteto-mode",
    label: "Poteto Mode",
    description: "Activate PStack's rigorous engineering method for this task",
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
fn poteto_mode_off_command_def() -> @posoco.CommandDef {
  @posoco.CommandDef::{
    id: "poteto-mode-off",
    label: "Poteto Mode Off",
    description: "Deactivate the PStack status indicator for this session",
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
pub impl @posoco.CommandPort for Pstack with fn commands(
  _self : Pstack,
) -> Array[@posoco.CommandDef] {
  [poteto_mode_command_def(), poteto_mode_off_command_def()]
}

///|
//// Reuse Skills' activation result. Publish the status indicator only after
//// activation succeeds; failures never produce a false "Mode On".
pub impl @posoco.CommandPort for Pstack with fn invoke(
  self : Pstack,
  id : String,
  _args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  match id {
    "poteto-mode" => {
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
    "poteto-mode-off" => {
      self.set_mode_active(false)
      @posoco.CommandOutcome::Success(
        feedback="🥔 Poteto Mode Off",
        structured=None,
        ui_hint=Some(@posoco.UiHint::None),
      )
    }
    other => raise @posoco.CommandError::NotFound(other)
  }
}

///|
pub impl @posoco.Lifecycle for Pstack with fn on_shutdown(
  self : Pstack,
) -> Unit {
  self.set_mode_active(false)
}

///|
pub extend Pstack with @posoco.Extension::{extension_id, manifest}

///|
pub extend Pstack with @posoco.CommandPort::{commands, invoke}

///|
pub extend Pstack with @posoco.Lifecycle::{on_shutdown}
