///|
fn normalize_path_separators(path : String) -> String {
  path.replace_all(old="\\", new="/")
}

///|
fn is_windows_drive_root(path : String) -> Bool {
  path.length() == 3 && path[1] == ':' && path[2] == '/'
}

///|
fn is_unc_root(path : String) -> Bool {
  if !path.has_prefix("//") {
    return false
  }
  let parts : Array[String] = []
  for part in path.split("/") {
    if !part.is_empty() {
      parts.push(part.to_owned())
    }
  }
  parts.length() == 2
}

///|
fn join_path(dir : String, name : String) -> String {
  if dir.is_empty() {
    name
  } else if dir.has_suffix("/") {
    dir + name
  } else {
    dir + "/" + name
  }
}

///|
/// Normalize separators used by canonical identity comparisons while
/// preserving POSIX, Windows drive, and UNC roots.
fn normalize_dir_input(path : String) -> String {
  let normalized = normalize_path_separators(path)
  let mut end = normalized.length()
  while end > 1 && normalized[end - 1] == '/' {
    let candidate = normalized[:end].to_owned()
    if candidate == "/" ||
      is_windows_drive_root(candidate) ||
      is_unc_root(candidate) {
      break
    }
    end = end - 1
  }
  if end == normalized.length() {
    normalized
  } else {
    normalized[:end].to_owned()
  }
}

///|
fn parent_dir(path : String) -> String? {
  let s = normalize_dir_input(path)
  if s == "/" || s.is_empty() || is_windows_drive_root(s) || is_unc_root(s) {
    return None
  }
  match s.rev_find("/") {
    None => None
    Some(0) => Some("/")
    Some(2) if s.length() >= 3 && s[1] == ':' => Some(s[:3].to_owned())
    Some(index) => {
      let parent = s[:index].to_owned()
      if parent == "" {
        None
      } else {
        Some(parent)
      }
    }
  }
}

///|
fn path_is_ancestor_or_same(path : String, ancestor : String) -> Bool {
  let path = normalize_dir_input(path)
  let ancestor = normalize_dir_input(ancestor)
  if path == ancestor {
    true
  } else if ancestor == "/" || ancestor.has_suffix("/") {
    path.has_prefix(ancestor)
  } else {
    path.has_prefix(ancestor + "/")
  }
}

///|
pub struct SkillDiscovery {
  fs : &@workspace.WorkspaceFs
  cwd : String
  home : String
  options : SkillDiscoveryOptions
}

///|
pub fn SkillDiscovery::SkillDiscovery(
  fs : &@workspace.WorkspaceFs,
  cwd~ : String,
  home~ : String,
  options? : SkillDiscoveryOptions = SkillDiscoveryOptions::default(),
) -> SkillDiscovery {
  { fs, cwd, home, options: options.snapshot() }
}

///|
async fn SkillDiscovery::detect_repo_root(
  self : SkillDiscovery,
  cwd : String,
  diagnostics : Array[SkillDiagnostic],
) -> String? noraise {
  match self.options.repo_root {
    Some(value) => {
      let configured = normalize_dir_input(value)
      if configured.is_empty() {
        return Some("")
      }
      let canonical = self.fs.realpath(configured) catch {
        _ => {
          diagnostics.push({
            severity: Warning,
            code: SkillPathFailed,
            path: configured,
            message: "configured repository root realpath failed; using lexical path",
          })
          configured
        }
      }
      Some(normalize_dir_input(canonical))
    }
    None => {
      let mut dir = cwd
      while true {
        let marker = join_path(dir, ".git")
        let marker_exists = self.fs.exists(marker) catch { _ => false }
        if marker_exists {
          return Some(dir)
        }
        match parent_dir(dir) {
          Some(parent) if parent != dir => dir = parent
          _ => return None
        }
      }
      None
    }
  }
}

///|
fn collision_diagnostic(
  shadowed : SkillDescriptor,
  winner : SkillDescriptor,
) -> SkillDiagnostic {
  {
    severity: Warning,
    code: Shadowed,
    path: shadowed.skill_md_path,
    message: "skill '" +
    shadowed.name +
    "' is shadowed by higher-precedence skill at " +
    winner.skill_md_path,
  }
}

///|
async fn SkillDiscovery::scan_root(
  self : SkillDiscovery,
  root : String,
  scope : SkillScope,
  canonical_boundary : String?,
  seen_paths : Map[String, Unit],
  winners : Map[String, SkillDescriptor],
  ordered : Array[SkillDescriptor],
  diagnostics : Array[SkillDiagnostic],
  candidate_count : Ref[Int],
  candidate_limit_reported : Ref[Bool],
  catalog_limit_reported : Ref[Bool],
) -> Unit noraise {
  // The candidate budget is global across all scopes. Once exhausted, lower-
  // precedence roots must not even be enumerated; WorkspaceFs::readdir
  // materializes a whole directory and could otherwise defeat the work bound.
  if candidate_count.val >= self.options.max_candidates {
    return
  }
  // Once an actual omitted skill has already established that the collision-
  // resolved catalog limit is binding, no lower-precedence root can contribute.
  if catalog_limit_reported.val {
    return
  }
  let present = self.fs.exists(root) catch {
    _ => {
      diagnostics.push({
        severity: Warning,
        code: RootStatFailed,
        path: root,
        message: "skill root stat failed",
      })
      return
    }
  }
  if !present {
    return
  }
  let root_kind = self.fs.kind(root, follow_symlink=true) catch {
    _ => {
      diagnostics.push({
        severity: Warning,
        code: RootStatFailed,
        path: root,
        message: "skill root kind check failed",
      })
      return
    }
  }
  if !(root_kind is @workspace.WorkspaceFileKind::Dir) {
    diagnostics.push({
      severity: Warning,
      code: RootStatFailed,
      path: root,
      message: "skill root is not a directory",
    })
    return
  }
  // Resolve the root once and perform subsequent directory I/O through that
  // canonical location. Repository roots that escape their trust boundary are
  // rejected before readdir, avoiding even filename disclosure through a
  // retargeted root symlink.
  let io_root = self.fs.realpath(root) catch {
    _ => {
      diagnostics.push({
        severity: Warning,
        code: RootStatFailed,
        path: root,
        message: "skill root realpath failed",
      })
      return
    }
  }
  let io_root = normalize_dir_input(io_root)
  match canonical_boundary {
    Some(boundary) if !self.options.allow_repository_external_symlinks &&
      !path_is_ancestor_or_same(io_root, boundary) => {
      diagnostics.push({
        severity: Warning,
        code: ExternalSymlinkRejected,
        path: root,
        message: "repository skill root resolves outside the repository boundary and was rejected",
      })
      return
    }
    _ => ()
  }
  let entries = self.fs.readdir(io_root, include_hidden=true) catch {
    _ => {
      diagnostics.push({
        severity: Warning,
        code: RootReadFailed,
        path: root,
        message: "skill root directory read failed",
      })
      return
    }
  }
  entries.sort()
  for entry in entries {
    // WorkspaceFs::readdir promises child names. Reject malformed entries so a
    // custom/hostile adapter cannot turn discovery into arbitrary path lookup.
    if entry.is_empty() ||
      entry == "." ||
      entry == ".." ||
      entry.length() > hard_max_path_segment_chars ||
      entry.contains("/") ||
      entry.contains("\\") ||
      entry.contains(":") ||
      contains_unsafe_control(entry) {
      diagnostics.push({
        severity: Warning,
        code: SkillPathFailed,
        path: root,
        message: "invalid skill-root directory entry was skipped",
      })
      continue
    }
    if candidate_count.val >= self.options.max_candidates {
      if !candidate_limit_reported.val {
        diagnostics.push({
          severity: Warning,
          code: DiscoveryLimitReached,
          path: root,
          message: "skill discovery candidate limit reached",
        })
        candidate_limit_reported.val = true
      }
      return
    }
    candidate_count.val = candidate_count.val + 1
    let dir = join_path(io_root, entry)
    let dir_kind = self.fs.kind(dir, follow_symlink=true) catch {
      _ => continue
    }
    if !(dir_kind is @workspace.WorkspaceFileKind::Dir) {
      continue
    }
    let skill_md = join_path(dir, "SKILL.md")
    let skill_kind = self.fs.kind(skill_md, follow_symlink=true) catch {
      _ => continue
    }
    if !(skill_kind is @workspace.WorkspaceFileKind::File) {
      continue
    }
    let real = self.fs.realpath(skill_md) catch {
      _ => {
        diagnostics.push({
          severity: Warning,
          code: SkillPathFailed,
          path: skill_md,
          message: "SKILL.md realpath failed",
        })
        continue
      }
    }
    let real = normalize_dir_input(real)
    if seen_paths.contains(real) {
      continue
    }
    let real_dir = match parent_dir(real) {
      Some(value) => value
      None => {
        diagnostics.push({
          severity: Warning,
          code: SkillPathFailed,
          path: real,
          message: "SKILL.md has no parent directory",
        })
        continue
      }
    }
    let canonical_candidate_dir = self.fs.realpath(dir) catch {
      _ => {
        diagnostics.push({
          severity: Warning,
          code: SkillPathFailed,
          path: dir,
          message: "skill directory realpath failed",
        })
        continue
      }
    }
    let canonical_candidate_dir = normalize_dir_input(canonical_candidate_dir)
    if canonical_candidate_dir != normalize_dir_input(real_dir) {
      diagnostics.push({
        severity: Warning,
        code: SkillPackageMismatch,
        path: skill_md,
        message: "SKILL.md resolves outside its skill directory package and was rejected",
      })
      continue
    }
    match canonical_boundary {
      Some(boundary) if !self.options.allow_repository_external_symlinks &&
        !path_is_ancestor_or_same(real_dir, boundary) => {
        diagnostics.push({
          severity: Warning,
          code: ExternalSymlinkRejected,
          path: skill_md,
          message: "repository skill resolves outside the repository boundary and was rejected",
        })
        continue
      }
      _ => ()
    }
    // Read the canonical file that was just validated rather than the logical
    // symlink path. This prevents a repo-controlled symlink retarget between
    // boundary validation and read from changing which file is consumed.
    let source = self.fs.read_file(real) catch {
      _ => {
        diagnostics.push({
          severity: Warning,
          code: SkillReadFailed,
          path: real,
          message: "canonical SKILL.md read failed",
        })
        // Do not mark the canonical path as seen: a lower-precedence alias may
        // still expose a different canonical file and should get a chance.
        continue
      }
    }
    // Re-resolve both the canonical file and the logical package entry after
    // the read. WorkspaceFs does not expose stable open handles, so this
    // detect-after-read check is the strongest available defense against a
    // symlink retarget during discovery. Changed content is discarded and
    // never enters the catalog.
    let real_after = self.fs.realpath(real) catch {
      _ => {
        diagnostics.push({
          severity: Warning,
          code: SkillPathFailed,
          path: real,
          message: "SKILL.md changed while being discovered",
        })
        continue
      }
    }
    let dir_after = self.fs.realpath(dir) catch {
      _ => {
        diagnostics.push({
          severity: Warning,
          code: SkillPathFailed,
          path: dir,
          message: "skill directory changed while being discovered",
        })
        continue
      }
    }
    if normalize_dir_input(real_after) != real ||
      normalize_dir_input(dir_after) != canonical_candidate_dir {
      diagnostics.push({
        severity: Warning,
        code: SkillPathFailed,
        path: skill_md,
        message: "skill package changed while being discovered and was rejected",
      })
      continue
    }
    // From this point onward the canonical source itself was readable and
    // stable across the read, so duplicate aliases should not re-parse or
    // re-report the same file.
    seen_paths.set(real, ())
    if source.length() > self.options.max_skill_file_chars {
      diagnostics.push({
        severity: Error,
        code: SkillFileTooLarge,
        path: real,
        message: "SKILL.md exceeds configured discovery size limit",
      })
      continue
    }
    match
      parse_discovered_skill_file(
        source,
        skill_md_path=real,
        skill_dir=real_dir,
        scope~,
        logical_dir_name=entry,
      ) {
      Err(reason) =>
        diagnostics.push({
          severity: Error,
          code: InvalidFrontmatter,
          path: real,
          message: reason,
        })
      Ok(parsed) => {
        for diagnostic in parsed.diagnostics {
          diagnostics.push(diagnostic)
        }
        match winners.get(parsed.descriptor.name) {
          Some(winner) =>
            diagnostics.push(collision_diagnostic(parsed.descriptor, winner))
          None => {
            if ordered.length() >= self.options.max_skills {
              if !catalog_limit_reported.val {
                diagnostics.push({
                  severity: Warning,
                  code: CatalogLimitReached,
                  path: root,
                  message: "skill catalog limit reached; lower-precedence skills were omitted",
                })
                catalog_limit_reported.val = true
              }
              return
            }
            winners.set(parsed.descriptor.name, parsed.descriptor)
            ordered.push(parsed.descriptor)
          }
        }
      }
    }
  }
}

///|
fn project_skill_roots(
  cwd : String,
  repo_root : String?,
  diagnostics : Array[SkillDiagnostic],
) -> Array[String] {
  let roots : Array[String] = []
  match repo_root {
    None => roots.push(join_path(cwd, ".agents/skills"))
    Some(stop) => {
      if stop.is_empty() || !path_is_ancestor_or_same(cwd, stop) {
        diagnostics.push({
          severity: Error,
          code: InvalidConfiguration,
          path: stop,
          message: "configured repository root is not an ancestor of cwd",
        })
        roots.push(join_path(cwd, ".agents/skills"))
        return roots
      }
      let mut dir = cwd
      while true {
        roots.push(join_path(dir, ".agents/skills"))
        if dir == stop {
          break
        }
        match parent_dir(dir) {
          Some(parent) if parent != dir => dir = parent
          _ => break
        }
      }
    }
  }
  roots
}

///|
/// Discover and collision-resolve all skills. Discovery reads each SKILL.md to
/// parse metadata, but only descriptors are retained; bodies are re-read at
/// activation time for context-level progressive disclosure.
pub async fn SkillDiscovery::discover(
  self : SkillDiscovery,
) -> SkillCatalog noraise {
  let ordered : Array[SkillDescriptor] = []
  let diagnostics : Array[SkillDiagnostic] = []
  match self.options.validate() {
    Err(reason) => {
      diagnostics.push({
        severity: Error,
        code: InvalidConfiguration,
        path: "",
        message: reason,
      })
      return { skills: ordered, diagnostics }
    }
    Ok(_) => ()
  }
  let seen_paths : Map[String, Unit] = Map([])
  let winners : Map[String, SkillDescriptor] = Map([])
  let candidate_count : Ref[Int] = { val: 0 }
  let candidate_limit_reported : Ref[Bool] = { val: false }
  let catalog_limit_reported : Ref[Bool] = { val: false }
  if self.options.include_repository {
    let cwd_input = normalize_dir_input(self.cwd)
    if cwd_input.is_empty() {
      diagnostics.push({
        severity: Error,
        code: InvalidConfiguration,
        path: self.cwd,
        message: "cwd must be non-empty when repository-skill discovery is enabled",
      })
    } else {
      let cwd = self.fs.realpath(cwd_input) catch {
        _ => {
          diagnostics.push({
            severity: Warning,
            code: SkillPathFailed,
            path: cwd_input,
            message: "cwd realpath failed; using lexical path for skill discovery",
          })
          cwd_input
        }
      }
      let cwd = normalize_dir_input(cwd)
      let repo_root = self.detect_repo_root(cwd, diagnostics)
      let repository_boundary = match repo_root {
        Some(root) if !root.is_empty() && path_is_ancestor_or_same(cwd, root) =>
          root
        _ => cwd
      }
      for root in project_skill_roots(cwd, repo_root, diagnostics) {
        self.scan_root(
          root,
          SkillScope::Repository,
          Some(repository_boundary),
          seen_paths,
          winners,
          ordered,
          diagnostics,
          candidate_count,
          candidate_limit_reported,
          catalog_limit_reported,
        )
      }
    }
  }
  if self.options.include_user {
    let home_input = normalize_dir_input(self.home)
    if home_input.is_empty() {
      diagnostics.push({
        severity: Error,
        code: InvalidConfiguration,
        path: self.home,
        message: "home must be non-empty when user-skill discovery is enabled",
      })
    } else {
      let home = self.fs.realpath(home_input) catch {
        _ => {
          diagnostics.push({
            severity: Warning,
            code: SkillPathFailed,
            path: home_input,
            message: "home realpath failed; using lexical path for user-skill discovery",
          })
          home_input
        }
      }
      self.scan_root(
        join_path(normalize_dir_input(home), ".agents/skills"),
        SkillScope::User,
        None,
        seen_paths,
        winners,
        ordered,
        diagnostics,
        candidate_count,
        candidate_limit_reported,
        catalog_limit_reported,
      )
    }
  }
  for configured_root in self.options.extra_roots {
    let root = normalize_dir_input(configured_root)
    if root.is_empty() {
      diagnostics.push({
        severity: Error,
        code: InvalidConfiguration,
        path: configured_root,
        message: "extra skill root must be non-empty",
      })
      continue
    }
    self.scan_root(
      root,
      SkillScope::Extra(root),
      None,
      seen_paths,
      winners,
      ordered,
      diagnostics,
      candidate_count,
      candidate_limit_reported,
      catalog_limit_reported,
    )
  }
  { skills: ordered, diagnostics }
}
