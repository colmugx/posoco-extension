///|
priv struct PendingSkillDir {
  /// Model-visible path used only to preserve the installed relative name.
  logical_path : String
  /// Canonical directory already proven to be inside the skill package. All
  /// directory I/O proceeds through this path so a validated symlink is not
  /// followed again after the containment check.
  canonical_path : String
  depth : Int
}

///|
priv struct SkillResourceListing {
  files : Array[String]
  truncated : Bool
  warnings : Array[String]
  warnings_omitted : Int
}

///|
fn record_listing_warning(
  warnings : Array[String],
  omitted : Ref[Int],
  limit : Int,
  message : String,
) -> Unit {
  if warnings.length() < limit {
    warnings.push(
      unicode_scalar_preview(message, hard_max_resource_warning_chars),
    )
  } else {
    omitted.val = omitted.val + 1
  }
}

///|
fn canonical_is_inside(path : String, root : String) -> Bool {
  let path = normalize_dir_input(path)
  let root = normalize_dir_input(root)
  if path == root {
    true
  } else if root == "/" || root.has_suffix("/") {
    path.has_prefix(root)
  } else {
    path.has_prefix(root + "/")
  }
}

///|
fn relative_from_root(path : String, root : String) -> String? {
  let path = normalize_dir_input(path)
  let root = normalize_dir_input(root)
  if path == root {
    Some("")
  } else if canonical_is_inside(path, root) {
    let start = if root.has_suffix("/") {
      root.length()
    } else {
      root.length() + 1
    }
    Some(path[start:].to_owned())
  } else {
    None
  }
}

///|
fn normalize_resource_path(path : String) -> Result[String, String] {
  if path.is_empty() {
    return Err("resource path must not be empty")
  }
  if path != path.trim().to_owned() {
    return Err("resource path must not contain leading or trailing whitespace")
  }
  let value = path
  if value.length() > hard_max_resource_path_chars {
    return Err("resource path exceeds runtime safety limit")
  }
  if value.has_prefix("/") {
    return Err("resource path must be relative to the skill directory")
  }
  if value.contains("\\") {
    return Err("resource path must use '/' separators")
  }
  // ':' is not a portable path-segment character and is drive/alternate-data-
  // stream syntax on Windows. Reject it consistently on every target.
  if value.contains(":") {
    return Err("resource path must not contain ':'")
  }
  if contains_unsafe_control(value) {
    return Err("resource path must not contain unsafe control characters")
  }
  let parts : Array[String] = []
  for part in value.split("/") {
    if part.is_empty() {
      return Err("resource path must not contain empty segments")
    }
    if part.length() > hard_max_path_segment_chars {
      return Err("resource path segment exceeds runtime safety limit")
    }
    if part == "." || part == ".." {
      return Err("resource path must not contain '.' or '..' segments")
    }
    parts.push(part.to_owned())
  }
  let normalized = parts.join("/")
  if normalized == "SKILL.md" {
    return Err("SKILL.md instructions must be loaded through skill activation")
  }
  Ok(normalized)
}

///|
async fn Skills::skill_location_is_stable(
  self : Skills,
  skill : SkillDescriptor,
) -> Bool noraise {
  let current_file = self.fs.realpath(skill.skill_md_path) catch {
    _ => return false
  }
  let current_file = normalize_dir_input(current_file)
  if current_file != normalize_dir_input(skill.skill_md_path) {
    return false
  }
  let current_dir = self.fs.realpath(skill.skill_dir) catch {
    _ => return false
  }
  normalize_dir_input(current_dir) == normalize_dir_input(skill.skill_dir)
}

///|
fn string_map_eq(a : Map[String, String], b : Map[String, String]) -> Bool {
  let mut a_count = 0
  for key, value in a {
    a_count = a_count + 1
    if b.get(key) != Some(value) {
      return false
    }
  }
  let mut b_count = 0
  for _, _ in b {
    b_count = b_count + 1
  }
  a_count == b_count
}

///|
fn descriptor_metadata_matches(
  discovered : SkillDescriptor,
  current : SkillDescriptor,
) -> Bool {
  discovered.name == current.name &&
  discovered.description == current.description &&
  discovered.license == current.license &&
  discovered.compatibility == current.compatibility &&
  discovered.allowed_tools == current.allowed_tools &&
  string_map_eq(discovered.metadata, current.metadata)
}

///|
async fn Skills::list_resources(
  self : Skills,
  skill : SkillDescriptor,
) -> SkillResourceListing noraise {
  let files : Array[String] = []
  let warnings : Array[String] = []
  let warnings_omitted : Ref[Int] = { val: 0, }
  if self.config.max_resource_entries == 0 ||
    self.config.max_resource_listing_chars == 0 {
    return { files, truncated: false, warnings, warnings_omitted: 0, }
  }
  let skill_root = normalize_dir_input(skill.skill_dir)
  let pending : Array[PendingSkillDir] = [
    { logical_path: skill_root, canonical_path: skill_root, depth: 0, },
  ]
  let seen_dirs : Map[String, Unit] = Map([(skill_root, ())])
  let mut cursor = 0
  let mut inspected_nodes = 0
  let mut listing_chars = 0
  let mut truncated = false
  while cursor < pending.length() {
    if files.length() >= self.config.max_resource_entries ||
      inspected_nodes >= self.config.max_resource_nodes {
      truncated = true
      break
    }
    let current = pending[cursor]
    cursor = cursor + 1
    // WorkspaceFs exposes path-based operations rather than stable directory
    // handles. Re-resolve immediately before and after readdir; if the path was
    // retargeted, discard the entire enumeration rather than allowing stale or
    // outside entries to enter model-visible resource metadata.
    let dir_before = self.fs.realpath(current.canonical_path) catch {
      _ => {
        record_listing_warning(
          warnings,
          warnings_omitted,
          self.config.max_resource_warnings,
          "resource directory changed before listing and was skipped: " +
          current.logical_path,
        )
        continue
      }
    }
    let dir_before = normalize_dir_input(dir_before)
    if dir_before != current.canonical_path ||
      !canonical_is_inside(dir_before, skill_root) {
      record_listing_warning(
        warnings,
        warnings_omitted,
        self.config.max_resource_warnings,
        "resource directory changed before listing and was skipped: " +
        current.logical_path,
      )
      continue
    }
    let entries = self.fs.readdir(current.canonical_path, include_hidden=true) catch {
      _ => {
        record_listing_warning(
          warnings,
          warnings_omitted,
          self.config.max_resource_warnings,
          "unable to list resource directory: " + current.logical_path,
        )
        continue
      }
    }
    let dir_after = self.fs.realpath(current.canonical_path) catch {
      _ => {
        record_listing_warning(
          warnings,
          warnings_omitted,
          self.config.max_resource_warnings,
          "resource directory changed while listing and its entries were discarded: " +
          current.logical_path,
        )
        continue
      }
    }
    let dir_after = normalize_dir_input(dir_after)
    if dir_after != current.canonical_path ||
      !canonical_is_inside(dir_after, skill_root) {
      record_listing_warning(
        warnings,
        warnings_omitted,
        self.config.max_resource_warnings,
        "resource directory changed while listing and its entries were discarded: " +
        current.logical_path,
      )
      continue
    }
    entries.sort()
    for entry in entries {
      if files.length() >= self.config.max_resource_entries ||
        inspected_nodes >= self.config.max_resource_nodes {
        truncated = true
        break
      }
      inspected_nodes = inspected_nodes + 1
      // WorkspaceFs::readdir is specified to return child names. Validate that
      // contract defensively so a hostile/custom adapter cannot smuggle path
      // traversal into the resource walker.
      if entry.is_empty() ||
        entry == "." ||
        entry == ".." ||
        entry.length() > hard_max_path_segment_chars ||
        entry.contains("/") ||
        entry.contains("\\") ||
        entry.contains(":") ||
        contains_unsafe_control(entry) {
        record_listing_warning(
          warnings,
          warnings_omitted,
          self.config.max_resource_warnings,
          "invalid resource directory entry was skipped",
        )
        continue
      }
      let logical_candidate = join_path(current.logical_path, entry)
      let canonical_candidate = join_path(current.canonical_path, entry)
      // Resolve first, then classify the canonical target. A follow-kind result
      // taken before realpath can become stale if a symlink is retargeted from
      // file to directory (or vice versa) between those operations.
      let real = self.fs.realpath(canonical_candidate) catch {
        _ => {
          record_listing_warning(
            warnings,
            warnings_omitted,
            self.config.max_resource_warnings,
            "unable to resolve resource: " + logical_candidate,
          )
          continue
        }
      }
      let real = normalize_dir_input(real)
      if !canonical_is_inside(real, skill_root) {
        record_listing_warning(
          warnings,
          warnings_omitted,
          self.config.max_resource_warnings,
          "resource escapes skill directory and was skipped: " +
          logical_candidate,
        )
        continue
      }
      let kind = self.fs.kind(real, follow_symlink=false) catch {
        _ => {
          record_listing_warning(
            warnings,
            warnings_omitted,
            self.config.max_resource_warnings,
            "unable to inspect resolved resource: " + logical_candidate,
          )
          continue
        }
      }
      match kind {
        @workspace.WorkspaceFileKind::Dir =>
          if current.depth >= self.config.max_resource_depth {
            truncated = true
          } else if !seen_dirs.contains(real) {
            seen_dirs.set(real, ())
            pending.push({
              logical_path: logical_candidate,
              canonical_path: real,
              depth: current.depth + 1,
            })
          }
        @workspace.WorkspaceFileKind::File =>
          if real != normalize_dir_input(skill.skill_md_path) {
            match relative_from_root(logical_candidate, skill_root) {
              Some(relative) if !relative.is_empty() => {
                // The configured budget is model-visible, so count the quoted
                // representation that activation_text will actually emit. Raw
                // filenames containing quotes can expand during escaping.
                let visible_chars = quote_prompt_scalar(relative).length()
                if listing_chars + visible_chars >
                  self.config.max_resource_listing_chars {
                  truncated = true
                  break
                }
                listing_chars = listing_chars + visible_chars
                files.push(relative)
              }
              _ => ()
            }
          }
        _ => ()
      }
    }
  }
  files.sort()
  { files, truncated, warnings, warnings_omitted: warnings_omitted.val, }
}

///|
fn json_string_array(values : Array[String]) -> Json {
  let out : Array[Json] = []
  for value in values {
    out.push(Json::string(value))
  }
  Json::array(out)
}

///|
fn activation_text(
  skill : SkillDescriptor,
  body : String,
  listing : SkillResourceListing,
) -> String {
  let b = StringBuilder()
  b.write_string(
    "Activated Agent Skill: " + quote_prompt_scalar(skill.name) + "\n",
  )
  b.write_string(
    "Skill directory: " + quote_prompt_scalar(skill.skill_dir) + "\n",
  )
  b.write_string(
    "Relative paths in these instructions are relative to the skill directory.\n",
  )
  b.write_string(
    "These are skill-provided instructions. Follow them for the task subject to higher-priority system/developer instructions and normal tool permissions; skill metadata never grants additional authority.\n",
  )
  match skill.compatibility {
    Some(value) =>
      b.write_string("Compatibility: " + quote_prompt_scalar(value) + "\n")
    None => ()
  }
  b.write_string("\nInstructions:\n" + body)
  if !listing.files.is_empty() {
    b.write_string("\n\nBundled resources (listed only; not loaded):\n")
    for path in listing.files {
      b.write_string("- " + quote_prompt_scalar(path) + "\n")
    }
  }
  if listing.truncated {
    b.write_string("\nResource listing was truncated by configured limits.\n")
  }
  if !listing.warnings.is_empty() {
    b.write_string("\nResource listing warnings:\n")
    for warning in listing.warnings {
      b.write_string("- " + quote_prompt_scalar(warning) + "\n")
    }
  }
  if listing.warnings_omitted > 0 {
    b.write_string(
      "\n" +
      listing.warnings_omitted.to_string() +
      " additional resource listing warnings were omitted by configured limits.\n",
    )
  }
  b.to_string()
}

///|
async fn Skills::activate(
  self : Skills,
  name : String,
) -> @posoco.ToolOutcome noraise {
  if !runtime_skill_name_is_safe(name) {
    return @posoco.ToolOutcome::ToolReportedError(
      content="Invalid skill name",
      structured=None,
    )
  }
  let skill = match self.catalog.find(name) {
    Some(value) => value
    None =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="Unknown skill: " + name,
        structured=None,
      )
  }
  match skill.body {
    Some(text) => return activate_builtin(skill, text, self.config)
    None => ()
  }
  if !self.skill_location_is_stable(skill) {
    return @posoco.ToolOutcome::ToolReportedError(
      content="Skill location changed after discovery; rediscover skills before activation: " +
        name,
      structured=None,
    )
  }
  let source = self.fs.read_file(skill.skill_md_path) catch {
    _ =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="Unable to read SKILL.md for skill: " + name,
        structured=None,
      )
  }
  if source.length() > self.config.max_activation_file_chars {
    return @posoco.ToolOutcome::ToolReportedError(
      content="SKILL.md exceeds configured activation file limit for: " + name,
      structured=None,
    )
  }
  if !self.skill_location_is_stable(skill) {
    return @posoco.ToolOutcome::ToolReportedError(
      content="Skill location changed while activating; rediscover skills before retrying: " +
        name,
      structured=None,
    )
  }
  let parsed = match
    reparse_activated_skill_file(
      source,
      skill_md_path=skill.skill_md_path,
      skill_dir=skill.skill_dir,
      scope=skill.scope,
    ) {
    Ok(value) => value
    Err(reason) =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="SKILL.md became invalid after discovery for '" +
          name +
          "': " +
          reason,
        structured=None,
      )
  }
  if !descriptor_metadata_matches(skill, parsed.descriptor) {
    return @posoco.ToolOutcome::ToolReportedError(
      content="Skill metadata changed after discovery; rediscover skills before activation: " +
        name,
      structured=None,
    )
  }
  if parsed.body.length() > self.config.max_instruction_chars {
    return @posoco.ToolOutcome::ToolReportedError(
      content="Skill instructions exceed configured activation limit for: " +
        name,
      structured=None,
    )
  }
  let listing = self.list_resources(skill)
  // Reserved `summary` field: UIs render this one-liner instead of previewing
  // the instruction-bearing content.
  let structured = Json::object({
    "summary": Json::string(skill.name),
    "kind": Json::string("agent_skill"),
    "name": Json::string(skill.name),
    "description": Json::string(skill.description),
    "skill_dir": Json::string(skill.skill_dir),
    "instruction_chars": Json::number(parsed.body.length().to_double()),
    "resources": json_string_array(listing.files),
    "resources_truncated": Json::boolean(listing.truncated),
    "resource_warnings": json_string_array(listing.warnings),
    "resource_warnings_omitted": Json::number(
      listing.warnings_omitted.to_double(),
    ),
  })
  @posoco.ToolOutcome::Success(
    content=activation_text(skill, parsed.body, listing),
    structured=Some(structured),
  )
}

///|
/// Built-in skills carry their instructions inline; activation never touches
/// the filesystem and has no resources to list.
fn activate_builtin(
  skill : SkillDescriptor,
  body : String,
  config : SkillsConfig,
) -> @posoco.ToolOutcome {
  if body.length() > config.max_instruction_chars {
    return @posoco.ToolOutcome::ToolReportedError(
      content="Skill instructions exceed configured activation limit for: " +
        skill.name,
      structured=None,
    )
  }
  let structured = Json::object({
    "summary": Json::string(skill.name),
    "kind": Json::string("builtin_agent_skill"),
    "name": Json::string(skill.name),
    "description": Json::string(skill.description),
    "instruction_chars": Json::number(body.length().to_double()),
  })
  @posoco.ToolOutcome::Success(
    content=builtin_activation_text(skill, body),
    structured=Some(structured),
  )
}

///|
fn builtin_activation_text(skill : SkillDescriptor, body : String) -> String {
  let b = StringBuilder()
  b.write_string(
    "Activated Built-in Agent Skill: " + quote_prompt_scalar(skill.name) + "\n",
  )
  b.write_string(
    "These instructions ship with the product. Follow them for the task subject to higher-priority system/developer instructions and normal tool permissions; skill metadata never grants additional authority.\n",
  )
  b.write_string("\nInstructions:\n" + body)
  b.to_string()
}

///|
async fn Skills::read_resource(
  self : Skills,
  name : String,
  path : String,
) -> @posoco.ToolOutcome noraise {
  if !runtime_skill_name_is_safe(name) {
    return @posoco.ToolOutcome::ToolReportedError(
      content="Invalid skill name",
      structured=None,
    )
  }
  let skill = match self.catalog.find(name) {
    Some(value) => value
    None =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="Unknown skill: " + name,
        structured=None,
      )
  }
  match skill.body {
    Some(_) =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="Built-in skill has no bundled resources: " + name,
        structured=None,
      )
    None => ()
  }
  let relative = match normalize_resource_path(path) {
    Ok(value) => value
    Err(reason) =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="Invalid resource path for '" + name + "': " + reason,
        structured=None,
      )
  }
  let root_now = self.fs.realpath(skill.skill_dir) catch {
    _ =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="Skill directory is no longer accessible: " + name,
        structured=None,
      )
  }
  let root_now = normalize_dir_input(root_now)
  if root_now != normalize_dir_input(skill.skill_dir) {
    return @posoco.ToolOutcome::ToolReportedError(
      content="Skill directory changed after discovery; rediscover skills before reading resources: " +
        name,
      structured=None,
    )
  }
  let candidate = join_path(skill.skill_dir, relative)
  let kind = self.fs.kind(candidate, follow_symlink=true) catch {
    _ =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="Skill resource not found: " + relative,
        structured=None,
      )
  }
  if !(kind is @workspace.WorkspaceFileKind::File) {
    return @posoco.ToolOutcome::ToolReportedError(
      content="Skill resource is not a regular file: " + relative,
      structured=None,
    )
  }
  let real = self.fs.realpath(candidate) catch {
    _ =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="Unable to resolve skill resource: " + relative,
        structured=None,
      )
  }
  let real = normalize_dir_input(real)
  if !canonical_is_inside(real, skill.skill_dir) {
    return @posoco.ToolOutcome::ToolReportedError(
      content="Skill resource escapes the discovered skill directory and was rejected: " +
        relative,
      structured=None,
    )
  }
  if real == normalize_dir_input(skill.skill_md_path) {
    return @posoco.ToolOutcome::ToolReportedError(
      content="SKILL.md instructions must be loaded through skill activation",
      structured=None,
    )
  }
  let content = self.fs.read_file(real) catch {
    _ =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="Unable to read skill resource as UTF-8 text: " + relative,
        structured=None,
      )
  }
  let real_after = self.fs.realpath(candidate) catch {
    _ =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="Skill resource changed while reading: " + relative,
        structured=None,
      )
  }
  let real_after = normalize_dir_input(real_after)
  if real_after != real || !canonical_is_inside(real_after, skill.skill_dir) {
    return @posoco.ToolOutcome::ToolReportedError(
      content="Skill resource changed while reading and was rejected: " +
        relative,
      structured=None,
    )
  }
  if content.length() > self.config.max_resource_chars {
    return @posoco.ToolOutcome::ToolReportedError(
      content="Skill resource exceeds configured text-read limit: " + relative,
      structured=None,
    )
  }
  @posoco.ToolOutcome::Success(
    content~,
    structured=Some(
      Json::object({
        "kind": Json::string("agent_skill_resource"),
        "skill": Json::string(name),
        "path": Json::string(relative),
        "content_chars": Json::number(content.length().to_double()),
      }),
    ),
  )
}
