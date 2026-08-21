///|
/// Product-grade Agent Skills extension state. Construction takes an ownership
/// snapshot of the validated catalog so tool schemas and lookup semantics stay
/// stable for the lifetime of one Agent composition. Construct a new Skills
/// value after rediscovery if installed skill metadata changes.
pub struct Skills {
  fs : &@workspace.WorkspaceFs
  catalog : SkillCatalog
  config : SkillsConfig
}

///|
/// Construct the runtime extension from a hand-built catalog (embedding,
/// tests). Config and catalog invariants are validated before any ToolDef is
/// exposed; manually supplied data is runtime data, so failures return
/// `Result` for the caller to recover from. The registration-form
/// constructor is `Skills::new`.
pub fn Skills::from_catalog(
  fs : &@workspace.WorkspaceFs,
  catalog~ : SkillCatalog,
  config? : SkillsConfig = SkillsConfig::default(),
) -> Result[Skills, String] {
  match config.validate() {
    Err(reason) => return Err(reason)
    Ok(_) => ()
  }
  match catalog.validate() {
    Err(reason) => return Err(reason)
    Ok(_) => ()
  }
  // Take ownership by snapshot rather than retaining mutable Array/Map values
  // supplied by the host. Tool schemas and lookup semantics must remain stable
  // for the lifetime of one Agent composition.
  let catalog = catalog.snapshot()
  Ok({ fs, catalog, config })
}

///|
/// Registration-form constructor: discovery, validation, and snapshot in one
/// step, shaped like every other Posoco extension constructor (`new`-named,
/// no Result/raise on the caller). Returns None when a precondition is
/// unsatisfied (statically invalid options/config, pathological discovered
/// data) — the extension simply does not register this run. Environment
/// problems (unreadable roots, broken SKILL.md files) are never construction
/// failures; they surface as catalog diagnostics. `Skills::from_catalog` is
/// the manual-catalog form for embedding/tests.
pub async fn Skills::new(
  fs : &@workspace.WorkspaceFs,
  cwd~ : String,
  home~ : String,
  discovery_options? : SkillDiscoveryOptions = SkillDiscoveryOptions::default(),
  config? : SkillsConfig = SkillsConfig::default(),
) -> Skills? noraise {
  match discovery_options.validate() {
    Err(_) => return None
    Ok(_) => ()
  }
  match config.validate() {
    Err(_) => return None
    Ok(_) => ()
  }
  let discovery = SkillDiscovery::new(
    fs,
    cwd~,
    home~,
    options=discovery_options,
  )
  let catalog = discovery.discover()
  match Skills::from_catalog(fs, catalog~, config~) {
    Ok(skills) => Some(skills)
    Err(_) => None
  }
}

///|
pub fn Skills::catalog(self : Skills) -> SkillCatalog {
  self.catalog.snapshot()
}

///|
pub fn Skills::config(self : Skills) -> SkillsConfig {
  self.config
}

///|
/// Host-driven activation entry point. Products can use this for explicit
/// user activation (for example a slash command or mention) without fabricating
/// a model ToolCall. It uses the same rediscovery/stability/resource-listing
/// checks as the ToolProvider activation path.
pub async fn Skills::activate_skill(
  self : Skills,
  name : String,
) -> @posoco.ToolOutcome noraise {
  self.activate(name)
}

///|
/// Host-driven resource read entry point paired with `activate_skill`.
/// Products can expose their own UI/command surface while retaining the same
/// skill-root containment, anti-TOCTOU, and size-limit enforcement.
pub async fn Skills::read_skill_resource(
  self : Skills,
  name : String,
  path : String,
) -> @posoco.ToolOutcome noraise {
  self.read_resource(name, path)
}
