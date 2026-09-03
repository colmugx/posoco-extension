///|
/// Path helpers. Vault paths are vault-relative (`folder/note.md`), never
/// absolute; the CLI resolves them against the selected vault.

///|
/// Normalize a vault-relative path: strip a leading `./`, collapse a trailing
/// `/`, reject absolute and parent-escaping forms.
pub fn normalize_vault_path(input : String) -> String {
  let mut p = input
  while p.has_prefix("./") {
    p = p[2:].to_owned()
  }
  while p.has_suffix("/") && p.length() > 1 {
    p = p[:p.length() - 1].to_owned()
  }
  if p.has_prefix("/") {
    return ""
  }
  for part in p.split("/") {
    if part == ".." {
      return ""
    }
  }
  p
}

///|
/// Is the path (or any ancestor) inside a reserved directory?
pub fn path_reserved(normalized : String) -> Bool {
  for prefix in reserved_prefixes() {
    if normalized == prefix || normalized.has_prefix("\{prefix}/") {
      return true
    }
  }
  false
}

///|
/// Prefix allowlist check; an empty list allows the whole vault. Both the
/// path itself and any prefix boundary must match (`notes` does not cover
/// `notes2/x.md`).
pub fn path_allowed(prefixes : Array[String], normalized : String) -> Bool {
  if prefixes.is_empty() {
    return true
  }
  for prefix in prefixes {
    let p = normalize_vault_path(prefix)
    if normalized == p || normalized.has_prefix("\{p}/") {
      return true
    }
  }
  false
}

///|
/// Full read-side gate: normalization, reserved dirs, then the allowlist.
/// Returns the normalized path on success, empty string on refusal.
pub fn check_read_path(config : ObsidianConfig, input : String) -> String {
  let p = normalize_vault_path(input)
  if p == "" || path_reserved(p) {
    return ""
  }
  if path_allowed(config.read_paths, p) {
    p
  } else {
    ""
  }
}

///|
/// Write-side gate: reserved dirs then the `write_paths` allowlist (empty =
/// whole vault). `read_only=true` refuses unconditionally, mirroring the
/// tool-listing gate so a write can never slip through by direct invoke.
pub fn check_write_path(config : ObsidianConfig, input : String) -> String {
  if config.read_only {
    return ""
  }
  let p = normalize_vault_path(input)
  if p == "" || path_reserved(p) {
    return ""
  }
  if path_allowed(config.write_paths, p) {
    p
  } else {
    ""
  }
}

///|
/// The CLI takes content values with literal `\n`/`\t` escapes (its own
/// help: "Use \n for newline, \t for tab in content values"). Escaped
/// char-by-char: `String::replace` only rewrites the first occurrence.
pub fn escape_cli_content(content : String) -> String {
  let sb = StringBuilder()
  for ch in content {
    match ch {
      '\n' => sb.write_string("\\n")
      '\t' => sb.write_string("\\t")
      c => sb.write_string(c.to_string())
    }
  }
  sb.to_string()
}
