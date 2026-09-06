///|
/// Candidate context file names, in priority order. First hit in a directory
/// wins; we do not merge multiple files from the same directory.
let context_candidates : Array[String] = ["AGENTS.md", "CLAUDE.md"]

///|
pub(all) struct ContextDocument {
  /// Absolute, realpath-resolved filesystem path. Used for dedup and rendered
  /// as the `source` attribute of the <cetas-context> envelope.
  path : String
  content : String
}

///|
/// Immutable bundle of all discovered context documents for one workspace.
pub(all) struct ContextBundle {
  /// ~/.cetas/agent/AGENTS.md (or CLAUDE.md). None if absent or unreadable.
  global : ContextDocument?
  /// Ancestor chain from filesystem root → cwd, root first. Each entry is a
  /// distinct realpath. Empty if no context files were found on the chain.
  ancestors : Array[ContextDocument]
  /// Non-fatal problems encountered while loading (read failures, etc.).
  /// Surfaces for diagnostics; does not block agent construction.
  warnings : Array[String]
}

///|
pub fn ContextBundle::empty() -> ContextBundle {
  { global: None, ancestors: [], warnings: [], }
}

///|
pub struct ContextLoader {
  fs : &@workspace.WorkspaceFs
  home : String
}

///|
pub fn ContextLoader::ContextLoader(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
) -> ContextLoader {
  { fs, home, }
}

///|
/// Join a directory and a filename with exactly one `/`.
fn join_path(dir : String, name : String) -> String {
  if dir.is_empty() {
    return name
  }
  if dir.has_suffix("/") {
    dir + name
  } else {
    dir + "/" + name
  }
}

///|
/// Parent directory of `p`. Returns None at filesystem root (`/`).
/// Purely lexical: normalizes trailing slash, splits on `/`, drops the last
/// non-empty segment.
fn parent_dir(p : String) -> String? {
  let s = if p.length() > 1 && p.has_suffix("/") {
    p[:p.length() - 1].to_owned()
  } else {
    p
  }
  if s == "/" || s == "" {
    return None
  }
  let parts : Array[String] = []
  for seg in s.split("/") {
    if seg != "" {
      parts.push(seg.to_owned())
    }
  }
  if parts.is_empty() {
    return None
  }
  ignore(parts.pop())
  if parts.is_empty() {
    // Was a single absolute segment like "/foo" → parent is "/".
    if s.has_prefix("/") {
      return Some("/")
    }
    return None
  }
  let joined = parts.join("/")
  if s.has_prefix("/") {
    Some("/" + joined)
  } else {
    Some(joined)
  }
}

///|
/// Try each candidate name in `dir`; return the first one that exists and
/// reads successfully. Updates `seen` with the realpath so ancestors can't
/// double-load a symlinked duplicate.
///
/// Returns:
/// - `Ok(Some(doc))` — found and loaded
/// - `Ok(None)` — no candidate exists in this directory (normal case)
/// - `Err(msg)` — a candidate existed but reading/resolving failed (warning)
async fn ContextLoader::load_first_candidate(
  self : ContextLoader,
  dir : String,
  seen : Map[String, Unit],
) -> Result[ContextDocument?, String] {
  for name in context_candidates {
    let candidate = join_path(dir, name)
    let exists = self.fs.exists(candidate) catch {
      _ => continue // stat failed → try next candidate; not a warning
    }
    if !exists {
      continue
    }
    let real = self.fs.realpath(candidate) catch {
      _ => return Err("realpath failed for \{candidate}")
    }
    if seen.contains(real) {
      return Ok(None)
    }
    let content = self.fs.read_file(candidate) catch {
      _ => return Err("read_file failed for \{candidate}")
    }
    seen.set(real, ())
    return Ok(Some({ path: real, content, }))
  }
  Ok(None)
}

///|
/// Load all context documents for the given cwd. Never raises: every error
/// is converted to a warning and loading continues.
pub async fn ContextLoader::load(
  self : ContextLoader,
  cwd : String,
) -> ContextBundle {
  let warnings : Array[String] = []
  let seen : Map[String, Unit] = Map([])
  let global_dir = join_path(self.home, ".cetas/agent")
  let global : ContextDocument? = match
    self.load_first_candidate(global_dir, seen) {
    Ok(Some(doc)) => Some(doc)
    Ok(None) => None
    Err(msg) => {
      warnings.push(msg)
      None
    }
  }
  let walked : Array[ContextDocument] = []
  let mut dir = cwd
  while true {
    match self.load_first_candidate(dir, seen) {
      Ok(Some(doc)) => walked.push(doc)
      Ok(None) => ()
      Err(msg) => warnings.push(msg)
    }
    match parent_dir(dir) {
      None => break
      Some(p) => if p == dir { break } else { dir = p }
    }
  }
  let ancestors : Array[ContextDocument] = []
  for i = walked.length() - 1; i >= 0; i = i - 1 {
    ancestors.push(walked[i])
  }
  { global, ancestors, warnings, }
}
