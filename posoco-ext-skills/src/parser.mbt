///|
fn strip_cr(s : String) -> String {
  if s.has_suffix("\r") {
    s[:s.length() - 1].to_owned()
  } else {
    s
  }
}

///|
priv struct SkillSourceParts {
  frontmatter : String
  body : String
}

///|
fn split_skill_source(source : String) -> Result[SkillSourceParts, String] {
  let lines : Array[String] = []
  for line in source.split("\n") {
    lines.push(line.to_owned())
  }
  if lines.is_empty() || strip_cr(lines[0]) != "---" {
    return Err("SKILL.md must start with YAML frontmatter")
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
      if frontmatter_chars > hard_max_frontmatter_chars {
        return Err("SKILL.md frontmatter exceeds runtime safety limit")
      }
      fm.push(line)
    }
    i = i + 1
  }
  if !closed {
    return Err("SKILL.md frontmatter is not terminated")
  }
  Ok({ frontmatter: fm.join("\n"), body: body.join("\n") })
}

///|
fn yaml_string(m : Map[String, @yaml.Yaml], key : String) -> String? {
  match m.get(key) {
    Some(@yaml.Yaml::String(value)) => Some(value)
    _ => None
  }
}

///|
fn escape_yaml_double_quoted(value : String) -> String {
  value.replace_all(old="\\", new="\\\\").replace_all(old="\"", new="\\\"")
}

///|
/// Cross-client compatibility fallback recommended by the Agent Skills client
/// guide: retry one common malformed form where an unquoted top-level
/// description contains a colon. No other YAML is rewritten.
fn repair_unquoted_description_colon(frontmatter : String) -> String? {
  let lines : Array[String] = []
  for line in frontmatter.split("\n") {
    lines.push(line.to_owned())
  }
  let mut changed = false
  for i = 0; i < lines.length(); i = i + 1 {
    let line = lines[i]
    if line.has_prefix("description:") {
      let raw = line[12:].to_owned().trim().to_owned()
      if !raw.is_empty() &&
        !raw.has_prefix("\"") &&
        !raw.has_prefix("'") &&
        raw != "|" &&
        raw != ">" &&
        raw.contains(":") {
        lines[i] = "description: \"" + escape_yaml_double_quoted(raw) + "\""
        changed = true
      }
    }
  }
  if changed {
    Some(lines.join("\n"))
  } else {
    None
  }
}

///|
fn load_yaml_mapping(
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
fn parse_yaml_mapping(
  frontmatter : String,
) -> Result[(Map[String, @yaml.Yaml], Bool), String] {
  match load_yaml_mapping(frontmatter) {
    Ok(mapping) => Ok((mapping, false))
    Err(original_reason) =>
      match repair_unquoted_description_colon(frontmatter) {
        Some(repaired) =>
          match load_yaml_mapping(repaired) {
            Ok(mapping) => Ok((mapping, true))
            Err(_) => Err(original_reason)
          }
        None => Err(original_reason)
      }
  }
}

///|
fn parent_basename(path : String) -> String? {
  let parts : Array[String] = []
  for part in normalize_path_separators(path).split("/") {
    if !part.is_empty() {
      parts.push(part.to_owned())
    }
  }
  parts.last()
}

///|
fn name_diagnostics(
  name : String,
  expected_dir_name : String?,
  path : String,
) -> Array[SkillDiagnostic] {
  let out : Array[SkillDiagnostic] = []
  if name.length() > 64 {
    out.push({
      severity: Warning,
      code: InvalidName,
      path,
      message: "skill name exceeds 64 characters",
    })
  }
  if name.has_prefix("-") || name.has_suffix("-") {
    out.push({
      severity: Warning,
      code: InvalidName,
      path,
      message: "skill name must not start or end with '-'",
    })
  }
  if name.contains("--") {
    out.push({
      severity: Warning,
      code: InvalidName,
      path,
      message: "skill name contains consecutive hyphens",
    })
  }
  for ch in name {
    if !(ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '-') {
      out.push({
        severity: Warning,
        code: InvalidName,
        path,
        message: "skill name should contain only lowercase ASCII letters, digits, and hyphens",
      })
      break
    }
  }
  match expected_dir_name {
    Some(parent) if parent != name =>
      out.push({
        severity: Warning,
        code: InvalidName,
        path,
        message: "skill name does not match parent directory: " + parent,
      })
    _ => ()
  }
  out
}

///|
fn optional_string(
  mapping : Map[String, @yaml.Yaml],
  key : String,
  path : String,
  diagnostics : Array[SkillDiagnostic],
) -> String? {
  match mapping.get(key) {
    None => None
    Some(@yaml.Yaml::String(value)) =>
      if value.length() > hard_max_optional_field_chars {
        diagnostics.push({
          severity: Warning,
          code: FieldTooLarge,
          path,
          message: "frontmatter field '" +
          key +
          "' exceeds runtime safety limit and was ignored",
        })
        None
      } else {
        Some(value)
      }
    Some(_) => {
      diagnostics.push({
        severity: Warning,
        code: MetadataIgnored,
        path,
        message: "frontmatter field '" +
        key +
        "' must be a string and was ignored",
      })
      None
    }
  }
}

///|
fn metadata_map(
  mapping : Map[String, @yaml.Yaml],
  path : String,
  diagnostics : Array[SkillDiagnostic],
) -> Map[String, String] {
  let out : Map[String, String] = Map([])
  match mapping.get("metadata") {
    None => ()
    Some(@yaml.Yaml::Map(values)) => {
      if values.length() > hard_max_metadata_entries {
        diagnostics.push({
          severity: Warning,
          code: MetadataLimitReached,
          path,
          message: "metadata exceeds runtime entry limit and was ignored",
        })
        return out
      }
      for key, value in values {
        if key.length() > hard_max_metadata_key_chars {
          diagnostics.push({
            severity: Warning,
            code: FieldTooLarge,
            path,
            message: "metadata key exceeds runtime safety limit and was ignored",
          })
          continue
        }
        match value {
          @yaml.Yaml::String(text) =>
            if text.length() > hard_max_metadata_value_chars {
              diagnostics.push({
                severity: Warning,
                code: FieldTooLarge,
                path,
                message: "metadata.'" +
                key +
                "' exceeds runtime safety limit and was ignored",
              })
            } else {
              out.set(key, text)
            }
          _ =>
            diagnostics.push({
              severity: Warning,
              code: MetadataIgnored,
              path,
              message: "metadata.'" + key + "' is not a string and was ignored",
            })
        }
      }
    }
    Some(_) =>
      diagnostics.push({
        severity: Warning,
        code: MetadataIgnored,
        path,
        message: "metadata must be a string-to-string mapping and was ignored",
      })
  }
  out
}

///|
fn parse_skill_file_with_expected_dir_name(
  source : String,
  skill_md_path~ : String,
  skill_dir~ : String,
  scope~ : SkillScope,
  expected_dir_name~ : String?,
) -> Result[ParsedSkill, String] {
  let parts = match split_skill_source(source) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let (mapping, repaired) = match parse_yaml_mapping(parts.frontmatter) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let name = match yaml_string(mapping, "name") {
    Some(value) if !value.trim().is_empty() => value
    _ => return Err("frontmatter requires non-empty name")
  }
  let description = match yaml_string(mapping, "description") {
    Some(value) if !value.trim().is_empty() => value
    _ => return Err("frontmatter requires non-empty description")
  }
  if contains_unsafe_control(name) {
    return Err("skill name contains unsafe control characters")
  }
  if name.length() > hard_max_skill_name_chars {
    return Err("skill name exceeds runtime safety limit")
  }
  if description.length() > hard_max_skill_description_chars {
    return Err("skill description exceeds runtime safety limit")
  }
  let diagnostics = name_diagnostics(name, expected_dir_name, skill_md_path)
  if repaired {
    diagnostics.push({
      severity: Warning,
      code: LenientYamlRepair,
      path: skill_md_path,
      message: "accepted an unquoted description containing ':' via compatibility repair",
    })
  }
  if description.length() > 1024 {
    diagnostics.push({
      severity: Warning,
      code: DescriptionTooLong,
      path: skill_md_path,
      message: "skill description exceeds 1024 characters",
    })
  }
  let compatibility = optional_string(
    mapping, "compatibility", skill_md_path, diagnostics,
  )
  match compatibility {
    Some(value) if value.length() > 500 =>
      diagnostics.push({
        severity: Warning,
        code: CompatibilityTooLong,
        path: skill_md_path,
        message: "skill compatibility exceeds 500 characters",
      })
    _ => ()
  }
  let descriptor : SkillDescriptor = {
    name,
    description,
    skill_md_path,
    skill_dir,
    scope,
    license: optional_string(mapping, "license", skill_md_path, diagnostics),
    compatibility,
    allowed_tools: optional_string(
      mapping, "allowed-tools", skill_md_path, diagnostics,
    ),
    metadata: metadata_map(mapping, skill_md_path, diagnostics),
  }
  Ok({ descriptor, body: parts.body, diagnostics })
}

///|
/// Parse a complete SKILL.md. Direct callers validate the standard name ↔
/// parent-directory convention against `skill_dir`. Discovery uses the logical
/// directory entry name instead so symlink-installed skills are validated
/// against their installation name, not the canonical target basename.
pub fn parse_skill_file(
  source : String,
  skill_md_path~ : String,
  skill_dir~ : String,
  scope~ : SkillScope,
) -> Result[ParsedSkill, String] {
  parse_skill_file_with_expected_dir_name(
    source,
    skill_md_path~,
    skill_dir~,
    scope~,
    expected_dir_name=parent_basename(skill_dir),
  )
}

///|
fn parse_discovered_skill_file(
  source : String,
  skill_md_path~ : String,
  skill_dir~ : String,
  scope~ : SkillScope,
  logical_dir_name~ : String,
) -> Result[ParsedSkill, String] {
  parse_skill_file_with_expected_dir_name(
    source,
    skill_md_path~,
    skill_dir~,
    scope~,
    expected_dir_name=Some(logical_dir_name),
  )
}

///|
fn reparse_activated_skill_file(
  source : String,
  skill_md_path~ : String,
  skill_dir~ : String,
  scope~ : SkillScope,
) -> Result[ParsedSkill, String] {
  // Name/path cosmetics were already diagnosed at discovery time. Activation
  // revalidates the authoritative metadata/body without manufacturing a new
  // warning from a canonical symlink target basename.
  parse_skill_file_with_expected_dir_name(
    source,
    skill_md_path~,
    skill_dir~,
    scope~,
    expected_dir_name=None,
  )
}
