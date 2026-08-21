///|
/// Provenance scope for a discovered skill. Scope participates in deterministic
/// name-collision precedence: repository > user > extra root.
pub(all) enum SkillScope {
  Repository
  User
  Extra(String)
} derive(Eq)

///|
pub(all) enum SkillDiagnosticSeverity {
  Warning
  Error
} derive(Eq)

///|
pub(all) enum SkillDiagnosticCode {
  InvalidConfiguration
  RootStatFailed
  RootReadFailed
  SkillPathFailed
  SkillReadFailed
  SkillPackageMismatch
  ExternalSymlinkRejected
  SkillFileTooLarge
  DiscoveryLimitReached
  CatalogLimitReached
  InvalidFrontmatter
  InvalidName
  DescriptionTooLong
  CompatibilityTooLong
  MetadataIgnored
  MetadataLimitReached
  FieldTooLarge
  LenientYamlRepair
  Shadowed
} derive(Eq)

// Runtime safety ceilings are intentionally much larger than the portable
// Agent Skills recommendations. Portable violations stay lenient warnings,
// while these absolute ceilings prevent one discovered file or manually
// constructed catalog from amplifying startup tool schemas / retained state.

///|
let hard_max_frontmatter_chars = 131072

///|
let hard_max_skill_name_chars = 1024

///|
let hard_max_skill_description_chars = 16384

///|
let hard_max_optional_field_chars = 16384

///|
let hard_max_metadata_entries = 128

///|
let hard_max_metadata_key_chars = 256

///|
let hard_max_metadata_value_chars = 16384

///|
let hard_max_runtime_skills = 1024

///|
let hard_max_resource_path_chars = 4096

///|
let hard_max_path_segment_chars = 255

///|
let hard_max_tool_name_chars = 128

///|
/// Canonical filesystem locations are host/adapter controlled rather than
/// portable Skill metadata, but they are returned at activation time. Keep a
/// wide absolute ceiling so one pathological path cannot amplify model-visible
/// output or retained catalog state without imposing ordinary portability
/// rules on valid long paths.
let hard_max_skill_location_chars = 32768

///|
/// Individual resource-walker warnings enter activation context. The warning
/// count is configurable; this separate per-entry ceiling bounds a single
/// filesystem-controlled diagnostic.
let hard_max_resource_warning_chars = 512

///|
fn is_unsafe_control_code(code : Int) -> Bool {
  code < 32 ||
  code == 127 ||
  (code >= 128 && code <= 159) ||
  code == 0x00AD ||
  code == 0x061C ||
  code == 0x180E ||
  (code >= 0x200B && code <= 0x200F) ||
  (code >= 0x2028 && code <= 0x202E) ||
  (code >= 0x2060 && code <= 0x2064) ||
  (code >= 0x2066 && code <= 0x206F) ||
  code == 0xFEFF ||
  (code >= 0xFFF9 && code <= 0xFFFB)
}

///|
fn contains_unsafe_control(value : String) -> Bool {
  for ch in value {
    if is_unsafe_control_code(ch.to_int()) {
      return true
    }
  }
  false
}

///|
fn runtime_skill_name_is_safe(value : String) -> Bool {
  !value.is_empty() &&
  value.length() <= hard_max_skill_name_chars &&
  !contains_unsafe_control(value)
}

///|
/// Return at most `max_scalars` Unicode scalar values without slicing a String
/// at an arbitrary UTF-16 code-unit offset. MoonBit String slicing requires a
/// scalar boundary; direct `value[:N]` can abort when N splits a surrogate pair.
fn unicode_scalar_prefix(value : String, max_scalars : Int) -> String {
  if max_scalars <= 0 {
    return ""
  }
  let out = StringBuilder::new()
  let mut count = 0
  for ch in value {
    if count >= max_scalars {
      break
    }
    out.write_char(ch)
    count = count + 1
  }
  out.to_string()
}

///|
/// Produce a bounded human-readable preview. If the input exceeds the scalar
/// budget, reserve the final scalar for an ellipsis.
fn unicode_scalar_preview(value : String, max_scalars : Int) -> String {
  if max_scalars <= 0 {
    return ""
  }
  let mut count = 0
  for _ in value {
    count = count + 1
    if count > max_scalars {
      if max_scalars == 1 {
        return "…"
      }
      return unicode_scalar_prefix(value, max_scalars - 1) + "…"
    }
  }
  value
}

///|
pub(all) struct SkillDiagnostic {
  severity : SkillDiagnosticSeverity
  code : SkillDiagnosticCode
  path : String
  message : String
}

///|
pub(all) struct SkillDescriptor {
  name : String
  description : String
  /// Canonical realpath of SKILL.md at discovery time.
  skill_md_path : String
  /// Canonical realpath of the skill directory at discovery time.
  skill_dir : String
  scope : SkillScope
  license : String?
  compatibility : String?
  /// Agent Skills standard experimental metadata. Stored for fidelity only;
  /// never interpreted as Posoco authorization.
  allowed_tools : String?
  metadata : Map[String, String]
}

///|
/// Copy mutable descriptor members so a runtime snapshot cannot be changed by
/// a caller retaining the original frontmatter metadata map.
fn SkillDescriptor::snapshot(self : SkillDescriptor) -> SkillDescriptor {
  {
    name: self.name,
    description: self.description,
    skill_md_path: self.skill_md_path,
    skill_dir: self.skill_dir,
    scope: self.scope,
    license: self.license,
    compatibility: self.compatibility,
    allowed_tools: self.allowed_tools,
    metadata: self.metadata.copy(),
  }
}

///|
pub(all) struct ParsedSkill {
  descriptor : SkillDescriptor
  /// Markdown body after YAML frontmatter. Discovery discards this value;
  /// activation re-reads SKILL.md and returns it on demand.
  body : String
  diagnostics : Array[SkillDiagnostic]
}

///|
pub(all) struct SkillCatalog {
  /// Collision-resolved skills. At most one descriptor per name when produced
  /// by SkillDiscovery. Skills::new re-validates this invariant for manually
  /// constructed catalogs.
  skills : Array[SkillDescriptor]
  diagnostics : Array[SkillDiagnostic]
}

///|
pub fn SkillCatalog::empty() -> SkillCatalog {
  { skills: [], diagnostics: [] }
}

///|
/// Internal ownership boundary used by Skills. Arrays and metadata maps are
/// copied so the composed extension is stable even if a host mutates values it
/// retained after construction.
fn SkillCatalog::snapshot(self : SkillCatalog) -> SkillCatalog {
  let skills : Array[SkillDescriptor] = []
  for skill in self.skills {
    skills.push(skill.snapshot())
  }
  { skills, diagnostics: self.diagnostics.copy() }
}

///|
pub fn SkillCatalog::find(
  self : SkillCatalog,
  name : String,
) -> SkillDescriptor? {
  for skill in self.skills {
    if skill.name == name {
      return Some(skill)
    }
  }
  None
}

///|
pub fn SkillCatalog::names(self : SkillCatalog) -> Array[String] {
  let out : Array[String] = []
  for skill in self.skills {
    out.push(skill.name)
  }
  out
}

///|
/// Validate invariants required by the runtime tool surface. Discovery already
/// produces a valid catalog, but callers may also construct SkillCatalog values
/// directly for embedding/tests.
pub fn SkillCatalog::validate(self : SkillCatalog) -> Result[Unit, String] {
  if self.skills.length() > hard_max_runtime_skills {
    return Err("skill catalog exceeds runtime skill-count safety limit")
  }
  let names : Map[String, Unit] = Map([])
  let paths : Map[String, Unit] = Map([])
  for skill in self.skills {
    if skill.name.trim().is_empty() {
      return Err("skill catalog contains an empty name")
    }
    if skill.description.trim().is_empty() {
      return Err(
        "skill catalog contains an empty description for '" + skill.name + "'",
      )
    }
    if contains_unsafe_control(skill.name) {
      return Err("skill catalog name contains unsafe control characters")
    }
    if skill.name.length() > hard_max_skill_name_chars {
      return Err(
        "skill catalog name exceeds runtime safety limit for '" +
        unicode_scalar_prefix(skill.name, 64) +
        "...'",
      )
    }
    if skill.description.length() > hard_max_skill_description_chars {
      return Err(
        "skill catalog description exceeds runtime safety limit for '" +
        skill.name +
        "'",
      )
    }
    for value in [skill.license, skill.compatibility, skill.allowed_tools] {
      match value {
        Some(text) if text.length() > hard_max_optional_field_chars =>
          return Err(
            "skill catalog optional field exceeds runtime safety limit for '" +
            skill.name +
            "'",
          )
        _ => ()
      }
    }
    if skill.metadata.length() > hard_max_metadata_entries {
      return Err(
        "skill catalog metadata exceeds runtime entry limit for '" +
        skill.name +
        "'",
      )
    }
    for key, value in skill.metadata {
      if key.length() > hard_max_metadata_key_chars ||
        value.length() > hard_max_metadata_value_chars {
        return Err(
          "skill catalog metadata exceeds runtime field limit for '" +
          skill.name +
          "'",
        )
      }
    }
    if skill.skill_md_path.is_empty() || skill.skill_dir.is_empty() {
      return Err(
        "skill catalog contains an empty canonical path for '" +
        skill.name +
        "'",
      )
    }
    if skill.skill_md_path.length() > hard_max_skill_location_chars ||
      skill.skill_dir.length() > hard_max_skill_location_chars {
      return Err(
        "skill catalog canonical location exceeds runtime safety limit for '" +
        skill.name +
        "'",
      )
    }
    let skill_path = normalize_path_separators(skill.skill_md_path)
    let skill_dir = normalize_dir_input(skill.skill_dir)
    if !skill_path.has_suffix("/SKILL.md") {
      return Err(
        "skill catalog SKILL.md path does not end with /SKILL.md for '" +
        skill.name +
        "'",
      )
    }
    match parent_dir(skill_path) {
      Some(parent) if normalize_dir_input(parent) == skill_dir => ()
      _ =>
        return Err(
          "skill catalog SKILL.md path is not inside its skill directory for '" +
          skill.name +
          "'",
        )
    }
    if names.contains(skill.name) {
      return Err("skill catalog contains duplicate name: " + skill.name)
    }
    let path_key = normalize_path_separators(skill.skill_md_path)
    if paths.contains(path_key) {
      return Err("skill catalog contains duplicate SKILL.md path: " + path_key)
    }
    names.set(skill.name, ())
    paths.set(path_key, ())
  }
  Ok(())
}

///|
pub(all) struct SkillDiscoveryOptions {
  /// Explicit repository root. None asks discovery to walk upward for `.git`.
  repo_root : String?
  /// Project/repository skills may come from untrusted source trees. Hosts can
  /// disable this scope until their own workspace trust policy allows it.
  include_repository : Bool
  /// Repository skill directories that resolve outside the repository boundary
  /// are rejected by default. Set this only when the host has separately
  /// decided that repo-controlled external symlink targets are trusted.
  allow_repository_external_symlinks : Bool
  include_user : Bool
  /// Additional roots are lower precedence than repository and user roots,
  /// and are considered in array order.
  extra_roots : Array[String]
  /// Maximum number of directory entries inspected across skill roots. This
  /// bounds pathological roots even though WorkspaceFs::readdir still
  /// materializes each individual directory listing.
  max_candidates : Int
  /// Maximum number of collision-resolved skills retained in the runtime
  /// catalog. This separately bounds startup prompt/tool-schema growth.
  max_skills : Int
  /// Maximum characters accepted for one SKILL.md during metadata discovery.
  /// WorkspaceFs currently reads whole UTF-8 files, so this is an acceptance
  /// limit rather than a partial-I/O limit.
  max_skill_file_chars : Int
}

///|
pub fn SkillDiscoveryOptions::default() -> SkillDiscoveryOptions {
  {
    repo_root: None,
    include_repository: true,
    allow_repository_external_symlinks: false,
    include_user: true,
    extra_roots: [],
    max_candidates: 1024,
    max_skills: 256,
    max_skill_file_chars: 1000000,
  }
}

///|
fn SkillDiscoveryOptions::snapshot(
  self : SkillDiscoveryOptions,
) -> SkillDiscoveryOptions {
  { ..self, extra_roots: self.extra_roots.copy() }
}

///|
pub fn SkillDiscoveryOptions::validate(
  self : SkillDiscoveryOptions,
) -> Result[Unit, String] {
  if self.max_candidates <= 0 {
    return Err("max_candidates must be greater than zero")
  }
  if self.max_skills <= 0 {
    return Err("max_skills must be greater than zero")
  }
  if self.max_skills > hard_max_runtime_skills {
    return Err("max_skills exceeds runtime skill-count safety limit")
  }
  if self.max_skill_file_chars <= 0 {
    return Err("max_skill_file_chars must be greater than zero")
  }
  Ok(())
}

///|
pub(all) struct SkillsConfig {
  /// Maximum characters contributed by the generic catalog prompt. Zero
  /// disables the generic catalog body without disabling tools.
  catalog_max_chars : Int
  /// If false, Skills contributes tools only. Product hosts can render the
  /// catalog through their own SystemPromptContributor (for example an XML
  /// envelope) without duplicate prompt disclosure.
  contribute_prompt : Bool
  activate_tool_name : String
  read_resource_tool_name : String
  /// Maximum total SKILL.md characters accepted during activation.
  max_activation_file_chars : Int
  /// Maximum instruction-body characters returned by activation.
  max_instruction_chars : Int
  /// Maximum number of resource files listed during activation. Zero means
  /// activation does not enumerate resource files.
  max_resource_entries : Int
  /// Maximum aggregate characters of model-visible resource paths emitted by
  /// one activation listing. Zero disables automatic resource enumeration.
  max_resource_listing_chars : Int
  /// Maximum detailed resource-walker warnings included in one activation.
  /// Additional warnings are counted but not copied into model context.
  max_resource_warnings : Int
  /// Maximum directory nesting traversed while listing bundled resources.
  /// Zero means only files directly under the skill directory are listed.
  max_resource_depth : Int
  /// Maximum filesystem entries inspected while building one activation's
  /// resource listing. This bounds wide/mostly-empty directory trees.
  max_resource_nodes : Int
  /// Maximum characters returned by one resource-read tool call.
  max_resource_chars : Int
}

///|
pub fn SkillsConfig::default() -> SkillsConfig {
  {
    catalog_max_chars: 8000,
    contribute_prompt: true,
    activate_tool_name: "activate_skill",
    read_resource_tool_name: "read_skill_resource",
    max_activation_file_chars: 1000000,
    max_instruction_chars: 32000,
    max_resource_entries: 200,
    max_resource_listing_chars: 20000,
    max_resource_warnings: 20,
    max_resource_depth: 6,
    max_resource_nodes: 2000,
    max_resource_chars: 100000,
  }
}

///|
fn validate_tool_name(label : String, value : String) -> Result[Unit, String] {
  if value.trim().is_empty() {
    return Err(label + " must be non-empty")
  }
  if value != value.trim().to_owned() {
    return Err(label + " must not contain leading or trailing whitespace")
  }
  if contains_unsafe_control(value) {
    return Err(label + " must not contain unsafe control characters")
  }
  if value.length() > hard_max_tool_name_chars {
    return Err(label + " exceeds runtime tool-name safety limit")
  }
  Ok(())
}

///|
pub fn SkillsConfig::validate(self : SkillsConfig) -> Result[Unit, String] {
  if self.catalog_max_chars < 0 {
    return Err("catalog_max_chars must be non-negative")
  }
  match validate_tool_name("activate_tool_name", self.activate_tool_name) {
    Err(reason) => return Err(reason)
    Ok(_) => ()
  }
  match
    validate_tool_name("read_resource_tool_name", self.read_resource_tool_name) {
    Err(reason) => return Err(reason)
    Ok(_) => ()
  }
  if self.activate_tool_name == self.read_resource_tool_name {
    return Err("skill tool names must be distinct")
  }
  if self.max_activation_file_chars <= 0 {
    return Err("max_activation_file_chars must be greater than zero")
  }
  if self.max_instruction_chars <= 0 {
    return Err("max_instruction_chars must be greater than zero")
  }
  if self.max_resource_entries < 0 {
    return Err("max_resource_entries must be non-negative")
  }
  if self.max_resource_listing_chars < 0 {
    return Err("max_resource_listing_chars must be non-negative")
  }
  if self.max_resource_warnings < 0 {
    return Err("max_resource_warnings must be non-negative")
  }
  if self.max_resource_depth < 0 {
    return Err("max_resource_depth must be non-negative")
  }
  if self.max_resource_nodes <= 0 {
    return Err("max_resource_nodes must be greater than zero")
  }
  if self.max_resource_chars <= 0 {
    return Err("max_resource_chars must be greater than zero")
  }
  Ok(())
}
