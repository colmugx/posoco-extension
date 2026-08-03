///|
/// A project workspace with a stable root and lexical path boundary.
pub(all) struct Workspace {
  root : String
}

///|
pub fn Workspace::new(root : String) -> Result[Workspace, String] {
  let trimmed = root.trim()
  if trimmed.length() == 0 {
    Err("workspace root must not be empty")
  } else {
    Ok(Workspace::{ root: trimmed.to_owned() })
  }
}

///|
pub fn Workspace::root(self : Workspace) -> String {
  self.root
}

///|
/// Resolve a user/model supplied path under the workspace root.
///
/// This first version deliberately performs lexical validation only. It rejects
/// absolute paths, Windows drive-prefixed paths, and any `..` segment. A host
/// filesystem adapter should additionally canonicalize the result and verify
/// symlinks before performing I/O.
pub fn Workspace::resolve(
  self : Workspace,
  requested : String,
) -> Result[String, String] {
  let path = requested.trim()
  if path.length() == 0 || path == "." {
    return Ok(self.root)
  }
  if path.has_prefix("/") || path.has_prefix("\\") {
    return Err("workspace path must be relative")
  }
  if path.length() >= 2 && path[1] == ':' {
    return Err("workspace path must not use a drive prefix")
  }
  let clean : Array[String] = []
  for segment in path.replace_all(old="\\", new="/").split("/") {
    let value = segment.to_owned()
    if value.length() == 0 || value == "." {
      continue
    }
    if value == ".." {
      return Err("workspace path must not escape the root")
    }
    clean.push(value)
  }
  if clean.is_empty() {
    Ok(self.root)
  } else if self.root.has_suffix("/") {
    Ok(self.root + clean.join("/"))
  } else {
    Ok(self.root + "/" + clean.join("/"))
  }
}

///|
pub impl @posoco.SystemPromptContributor for Workspace with fn system_prompt(
  self : Workspace,
) -> String {
  "The active workspace root is `" + self.root + "`. Treat it as the default boundary for file and command operations. Do not access paths outside it unless the host explicitly grants permission."
}

///|
pub impl @posoco.Extension for Workspace with fn extension_id(
  _self : Workspace,
) -> String {
  "posoco_ext_workspace"
}

///|
pub impl @posoco.Extension for Workspace with fn manifest(
  self : Workspace,
) -> @posoco.ExtensionManifest {
  let manifest = @posoco.ExtensionManifest::empty(id="posoco_ext_workspace")
  { ..manifest, prompt_contributors: [self] }
}

///|
pub extend Workspace with @posoco.Extension::{extension_id, manifest}
