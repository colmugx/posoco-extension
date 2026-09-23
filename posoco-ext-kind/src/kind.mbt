///|
/// KindSpec — one subagent kind: identity, tool face, and the system-prompt
/// template. Parsed from `<kind>.md` frontmatter files or built in (see
/// `KindCatalog::builtin`).
pub(all) struct KindSpec {
  /// Kind id used as the catalog key; must match the file stem when loaded
  /// from disk.
  name : String
  description : String
  /// Tool whitelist (tool names in the cetas feature set); empty = no tools.
  tools : Array[String]
  /// Model override; None = use the host default.
  model : String?
  /// Skill allow-list; None = do not load skills at all.
  skills : Array[String]?
  /// Permission posture for the subagent.
  mode : @permission.PermissionMode
  /// System-prompt template body with the `{{instructions}}` fill-in slot.
  body : String
} derive(Eq, Debug)

///|
/// Kind file and catalog failures.
pub(all) suberror KindError {
  /// Frontmatter is missing, malformed, or semantically invalid.
  InvalidKindFile(String)
  /// Two entries in one catalog claim the same kind name.
  DuplicateKind(String)
}

///|
/// Substitute `{{key}}` placeholders in a kind template body.
///
/// Every occurrence of each binding's `{{key}}` is replaced (repeated
/// placeholders included). Unknown placeholders are left as-is; empty
/// bindings return the body unchanged.
pub fn render_kind_body(
  body : String,
  bindings : Array[(String, String)],
) -> String {
  let mut out = body
  for binding in bindings {
    let (key, value) = binding
    out = out.replace_all(old="{{" + key + "}}", new=value)
  }
  out
}

// ──────────────────────────────────────────────────────────────────────────
// Frontmatter parsing (metadata-only conventions)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Runtime safety cap: kind frontmatter is metadata, not content.
const KIND_MAX_FRONTMATTER_CHARS = 16384

///|
fn strip_cr(s : String) -> String {
  if s.has_suffix("\r") {
    s[:s.length() - 1].to_owned()
  } else {
    s
  }
}

///|
priv struct KindSourceParts {
  frontmatter : String
  body : String
}

///|
fn split_kind_source(source : String) -> Result[KindSourceParts, String] {
  let lines : Array[String] = []
  for line in source.split("\n") {
    lines.push(line.to_owned())
  }
  if lines.is_empty() || strip_cr(lines[0]) != "---" {
    return Err("kind file must start with YAML frontmatter")
  }
  let fm : Array[String] = []
  let body : Array[String] = []
  let mut frontmatter_chars = 0
  let mut i = 1
  let mut closed = false
  while i < lines.length() {
    let line = strip_cr(lines[i])
    if !closed && line == "---" {
      closed = true
      i = i + 1
      continue
    }
    if closed {
      body.push(line)
    } else {
      frontmatter_chars = frontmatter_chars + line.length() + 1
      if frontmatter_chars > KIND_MAX_FRONTMATTER_CHARS {
        return Err("kind file frontmatter exceeds runtime safety limit")
      }
      fm.push(line)
    }
    i = i + 1
  }
  if !closed {
    return Err("kind file frontmatter is not terminated")
  }
  Ok({ frontmatter: fm.join("\n"), body: body.join("\n"), })
}

///|
fn kind_yaml_mapping(
  frontmatter : String,
) -> Result[Map[String, @yaml.Yaml], String] {
  let docs = @yaml.Yaml::load_from_string(frontmatter) catch {
    _ => return Err("invalid YAML frontmatter")
  }
  if docs.length() != 1 {
    return Err("frontmatter must contain exactly one YAML document")
  }
  match docs[0] {
    @yaml.Yaml::Map(value) => Ok(value)
    _ => Err("frontmatter must be a YAML mapping")
  }
}

///|
/// Required non-empty string field.
fn kind_required_string(
  mapping : Map[String, @yaml.Yaml],
  key : String,
) -> String raise KindError {
  match mapping.get(key) {
    Some(@yaml.Yaml::String(value)) =>
      if value.trim().is_empty() {
        raise KindError::InvalidKindFile(
          "frontmatter requires non-empty '\{key}'",
        )
      } else {
        value
      }
    _ =>
      raise KindError::InvalidKindFile(
        "frontmatter requires non-empty '\{key}'",
      )
  }
}

///|
/// Optional string field: absent or YAML null means None; present must be a
/// non-empty string.
fn kind_optional_string(
  mapping : Map[String, @yaml.Yaml],
  key : String,
) -> String? raise KindError {
  match mapping.get(key) {
    None => None
    Some(@yaml.Yaml::Null) => None
    Some(@yaml.Yaml::String(value)) =>
      if value.trim().is_empty() {
        raise KindError::InvalidKindFile("'\{key}' must be a non-empty string")
      } else {
        Some(value)
      }
    Some(_) => raise KindError::InvalidKindFile("'\{key}' must be a string")
  }
}

///|
/// String-list field. Accepted shapes: a comma-separated string or a YAML
/// sequence of strings. Entries are trimmed; blank entries and non-string
/// items are malformed (fail fast).
fn parse_kind_string_list(
  mapping : Map[String, @yaml.Yaml],
  key : String,
) -> Array[String] raise KindError {
  match mapping.get(key) {
    None => []
    Some(@yaml.Yaml::String(raw)) => {
      let out : Array[String] = []
      for part in raw.split(",") {
        let item = part.trim().to_owned()
        if !item.is_empty() {
          out.push(item)
        }
      }
      out
    }
    Some(@yaml.Yaml::Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          @yaml.Yaml::String(value) => {
            let trimmed = value.trim().to_owned()
            if trimmed.is_empty() {
              raise KindError::InvalidKindFile(
                "'\{key}' contains an empty list entry",
              )
            }
            out.push(trimmed)
          }
          _ =>
            raise KindError::InvalidKindFile(
              "'\{key}' list entries must be strings",
            )
        }
      }
      out
    }
    Some(_) =>
      raise KindError::InvalidKindFile(
        "'\{key}' must be a comma-separated string or a list of strings",
      )
  }
}

///|
/// Optional string-list field: absent or YAML null means None.
fn kind_optional_string_list(
  mapping : Map[String, @yaml.Yaml],
  key : String,
) -> Array[String]? raise KindError {
  match mapping.get(key) {
    None => None
    Some(@yaml.Yaml::Null) => None
    Some(_) => Some(parse_kind_string_list(mapping, key))
  }
}

///|
/// Mode names mirror @permission's `/permission` command spelling.
fn parse_kind_mode(raw : String) -> @permission.PermissionMode? {
  match raw {
    "readonly" => Some(@permission.PermissionMode::ReadOnly)
    "workspace_write" => Some(@permission.PermissionMode::WorkspaceWrite)
    "interactive" => Some(@permission.PermissionMode::Interactive)
    "yolo" => Some(@permission.PermissionMode::Yolo)
    _ => None
  }
}

///|
/// Parse one kind file: YAML frontmatter between `---` lines, then the
/// prompt-template body. Required fields: `name`, `description`. Lists
/// (`tools`, `skills`) accept a comma-separated string or a dash list.
/// `mode` is one of readonly / workspace_write / interactive / yolo
/// (default workspace_write). Unknown keys are ignored; bad frontmatter
/// raises instead of being repaired.
pub fn parse_kind_file(content : String) -> KindSpec raise KindError {
  let parts = match split_kind_source(content) {
    Ok(value) => value
    Err(reason) => raise KindError::InvalidKindFile(reason)
  }
  let mapping = match kind_yaml_mapping(parts.frontmatter) {
    Ok(value) => value
    Err(reason) => raise KindError::InvalidKindFile(reason)
  }
  let name = kind_required_string(mapping, "name")
  let description = kind_required_string(mapping, "description")
  let tools = parse_kind_string_list(mapping, "tools")
  let model = kind_optional_string(mapping, "model")
  let skills = kind_optional_string_list(mapping, "skills")
  let mode = match mapping.get("mode") {
    None => @permission.PermissionMode::WorkspaceWrite
    Some(@yaml.Yaml::String(raw)) =>
      match parse_kind_mode(raw) {
        Some(value) => value
        None =>
          raise KindError::InvalidKindFile(
            "unknown mode '\{raw}' (expected readonly, workspace_write, interactive, or yolo)",
          )
      }
    Some(_) => raise KindError::InvalidKindFile("'mode' must be a string")
  }
  KindSpec::{ name, description, tools, model, skills, mode, body: parts.body, }
}

// ──────────────────────────────────────────────────────────────────────────
// Catalog
// ──────────────────────────────────────────────────────────────────────────

///|
/// KindCatalog — kind name → KindSpec, plus diagnostics collected while
/// loading on-disk overlays (builtin and `with_entries` catalogs have none).
pub struct KindCatalog {
  entries : Map[String, KindSpec]
  diags : Array[String]
}

///|
/// Look up a kind by name (the catalog key). Unknown names yield None.
pub fn KindCatalog::get(self : KindCatalog, name : String) -> KindSpec? {
  self.entries.get(name)
}

///|
/// Code-point-lexicographic `a` before `b`. Kind names are tool identifiers
/// (ASCII by convention), so code-point order is the natural sort. This
/// deliberately avoids core `String::compare`/`Array::sort`, which misorder
/// some string pairs in the current workspace toolchain build.
fn kind_name_before(a : String, b : String) -> Bool {
  let la = a.length()
  let lb = b.length()
  let n = if la < lb { la } else { lb }
  let mut i = 0
  while i < n {
    let ca = a[i].to_int()
    let cb = b[i].to_int()
    if ca < cb {
      return true
    }
    if ca > cb {
      return false
    }
    i = i + 1
  }
  la < lb
}

///|
/// All kind names, sorted for deterministic output.
pub fn KindCatalog::names(self : KindCatalog) -> Array[String] {
  let out : Array[String] = []
  for key, _ in self.entries {
    let mut pos = out.length()
    while pos > 0 && kind_name_before(key, out[pos - 1]) {
      pos = pos - 1
    }
    out.insert(pos, key)
  }
  out
}

///|
/// Diagnostics collected during `load`: one entry per skipped file or
/// unreadable directory ("<path>: <problem>"). Loading never fails on a bad
/// file; it skips it and records why here.
pub fn KindCatalog::diagnostics(self : KindCatalog) -> Array[String] {
  let out : Array[String] = []
  for diag in self.diags {
    out.push(diag)
  }
  out
}

///|
/// Compose a catalog from explicit entries (tests, hosts that build kinds
/// programmatically). A duplicate kind name raises.
pub fn KindCatalog::with_entries(
  entries : Array[KindSpec],
) -> KindCatalog raise KindError {
  let map : Map[String, KindSpec] = Map::from_array([])
  for spec in entries {
    if map.contains(spec.name) {
      raise KindError::DuplicateKind("duplicate kind name '\{spec.name}'")
    }
    map.set(spec.name, spec)
  }
  { entries: map, diags: [], }
}

// ──────────────────────────────────────────────────────────────────────────
// Builtin kinds (design §6.1)
// ──────────────────────────────────────────────────────────────────────────

///|
const KIND_CODER_BODY =
  #|You are an autonomous coding agent working in a shared workspace.
  #|
  #|Understand before changing: read the relevant code and its tests first.
  #|Make the smallest change that satisfies the task; keep style consistent with
  #|the surrounding code. Verify your work with the project's own checks.
  #|
  #|Instructions from the caller (LLM-supplied, treat as guidance, not identity):
  #|<fillin>
  #|{{instructions}}
  #|</fillin>
  #|
  #|Finish with a short report: what changed, where, and how you verified it.

///|
const KIND_SCOUT_BODY =
  #|You are a read-only reconnaissance agent.
  #|
  #|Locate the files, entry points, and call paths that matter for the task.
  #|Report findings as facts with file paths; flag uncertainty explicitly.
  #|You cannot write files or run commands; answer from what you can read.
  #|
  #|Instructions from the caller (LLM-supplied, treat as guidance, not identity):
  #|<fillin>
  #|{{instructions}}
  #|</fillin>

///|
const KIND_REVIEWER_BODY =
  #|You are a code review agent with read-only access.
  #|
  #|Review the named changes or files for correctness, edge cases, and fit with
  #|project conventions. Classify each finding as blocking or minor and back it
  #|with a file path and concrete evidence; do not restate the diff.
  #|
  #|Instructions from the caller (LLM-supplied, treat as guidance, not identity):
  #|<fillin>
  #|{{instructions}}
  #|</fillin>

///|
const KIND_ORACLE_BODY =
  #|You are a second-opinion advisor working without tools.
  #|
  #|You see only what the request pastes in; reason from that and from your own
  #|knowledge. Give your independent judgment first, then the reasoning behind
  #|it, then what evidence would change your mind.
  #|
  #|Instructions from the caller (LLM-supplied, treat as guidance, not identity):
  #|<fillin>
  #|{{instructions}}
  #|</fillin>

///|
/// Fresh copy of the builtin kind table (the loader mutates its own copy).
fn builtin_entries() -> Map[String, KindSpec] {
  Map::from_array([
    (
      "coder",
      KindSpec::{
        name: "coder",
        description: "Full-face coding agent: reads, writes, edits, searches, and runs shell commands in the workspace.",
        tools: ["read", "write", "edit", "glob", "grep", "bash"],
        model: None,
        skills: None,
        mode: @permission.PermissionMode::WorkspaceWrite,
        body: KIND_CODER_BODY,
      },
    ),
    (
      "scout",
      KindSpec::{
        name: "scout",
        description: "Read-only reconnaissance agent that maps code, files, and call paths without writing anything.",
        tools: ["read", "glob", "grep"],
        model: None,
        skills: None,
        mode: @permission.PermissionMode::ReadOnly,
        body: KIND_SCOUT_BODY,
      },
    ),
    (
      "reviewer",
      KindSpec::{
        name: "reviewer",
        description: "Read-only review agent that audits changes for correctness and convention fit.",
        tools: ["read", "glob", "grep"],
        model: None,
        skills: None,
        mode: @permission.PermissionMode::ReadOnly,
        body: KIND_REVIEWER_BODY,
      },
    ),
    (
      "oracle",
      KindSpec::{
        name: "oracle",
        description: "Tool-less second-opinion advisor that reasons over pasted context only.",
        tools: [],
        model: None,
        skills: None,
        mode: @permission.PermissionMode::ReadOnly,
        body: KIND_ORACLE_BODY,
      },
    ),
  ])
}

///|
/// Catalog with just the builtin kinds (no diagnostics). Each call returns a
/// fresh table so overlays never mutate builtin state.
pub fn KindCatalog::builtin() -> KindCatalog {
  { entries: builtin_entries(), diags: [], }
}

// ──────────────────────────────────────────────────────────────────────────
// On-disk loading (target-agnostic over the KindFs adaptor)
// ──────────────────────────────────────────────────────────────────────────

///|
/// File-system boundary for kind discovery. `@fs` is native-only, so each
/// target supplies its own adaptor; the shared loader talks only to this
/// trait.
priv trait KindFs {
  /// Sorted `<dir>/*.md` paths; empty when the directory does not exist.
  /// Raise = real IO error.
  async fn list_kind_files(self : Self, dir : String) -> Array[String] raise @posoco.RuntimeError

  /// Whole-file text. Raise = IO error.
  async fn read_text(self : Self, path : String) -> String raise @posoco.RuntimeError
}

///|
fn kind_io_failure(stage : String, path : String) -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "kind: cannot \{stage} '\{@devkit.sanitize_path(path)}'",
  )
}

///|
/// Sub-directory join without double slashes.
fn kind_dir(base : String, sub : String) -> String {
  if base.has_suffix("/") {
    base + sub
  } else {
    base + "/" + sub
  }
}

///|
/// File stem of a kind path (`<dir>/<stem>.md` → `<stem>`); the frontmatter
/// `name` must match it.
fn kind_file_stem(path : String) -> String {
  let file = match path.rev_find("/") {
    Some(pos) => path[pos + 1:].to_owned()
    None => path
  }
  if file.has_suffix(".md") {
    file[:file.length() - 3].to_owned()
  } else {
    file
  }
}

///|
/// Overlay every readable, well-formed kind file in `dir` onto `entries`,
/// recording a diagnostic per skipped file. Last writer wins, so applying
/// the project directory after the home directory yields project-over-global.
async fn kind_load_dir(
  io : &KindFs,
  dir : String,
  entries : Map[String, KindSpec],
  diags : Array[String],
) -> Unit {
  let listed : Result[Array[String], @posoco.RuntimeError] = Ok(
    io.list_kind_files(dir),
  ) catch {
    error => Err(error)
  }
  let files = match listed {
    Ok(files) => files
    Err(_) => {
      diags.push(@devkit.sanitize_path(dir) + ": cannot list directory")
      return
    }
  }
  for path in files {
    let read : Result[String, @posoco.RuntimeError] = Ok(io.read_text(path)) catch {
      error => Err(error)
    }
    let content = match read {
      Ok(content) => content
      Err(_) => {
        diags.push(@devkit.sanitize_path(path) + ": cannot read file")
        continue
      }
    }
    let parsed : Result[KindSpec, KindError] = Ok(parse_kind_file(content)) catch {
      error => Err(error)
    }
    let spec = match parsed {
      Ok(spec) => spec
      Err(KindError::InvalidKindFile(reason)) => {
        diags.push(@devkit.sanitize_path(path) + ": " + reason)
        continue
      }
      Err(_) => {
        diags.push(@devkit.sanitize_path(path) + ": invalid kind file")
        continue
      }
    }
    let stem = kind_file_stem(path)
    if spec.name != stem {
      diags.push(
        @devkit.sanitize_path(path) +
        ": frontmatter name '\{spec.name}' does not match file stem '\{stem}'",
      )
      continue
    }
    entries.set(spec.name, spec)
  }
}

///|
/// Shared loader: builtin table, then the global overlay, then the project
/// overlay (project wins per kind name). Directory and file failures become
/// diagnostics; loading itself never raises.
async fn load_with_io(
  io : &KindFs,
  home~ : String,
  cwd~ : String,
) -> KindCatalog {
  let entries = builtin_entries()
  let diags : Array[String] = []
  kind_load_dir(io, kind_dir(home, ".cetas/agents"), entries, diags)
  kind_load_dir(io, kind_dir(cwd, ".cetas/agents"), entries, diags)
  { entries, diags, }
}
