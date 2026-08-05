///|

///|
/// Candidate context file names, in priority order. First hit in a directory
/// wins; we do not merge multiple files from the same directory.
let context_candidates : Array[String] = ["AGENTS.md", "CLAUDE.md"]

///|
/// One loaded context document.
pub(all) struct ContextDocument {
  /// Absolute, realpath-resolved filesystem path. Used for dedup and rendered
  /// as the `source` attribute of the <cetas-context> envelope.
  path : String
  /// Full file contents.
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
/// Empty bundle — no global, no ancestors, no warnings.
pub fn ContextBundle::empty() -> ContextBundle {
  { global: None, ancestors: [], warnings: [] }
}

///|
/// ContextLoader discovers and reads context files via an injected
/// `WorkspaceFs`. The `home` directory is injected (not hardcoded) so tests
/// can substitute it.
pub struct ContextLoader {
  fs : &@workspace.WorkspaceFs
  home : String
}

///|
pub fn ContextLoader::new(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
) -> ContextLoader {
  { fs, home }
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
/// non-empty segment. Mirrors the approach in `normalize_lexical` (policy.mbt).
fn parent_dir(p : String) -> String? {
  // Normalize trailing slash (but keep root "/").
  let s = if p.length() > 1 && p.has_suffix("/") {
    p[:p.length() - 1].to_owned()
  } else {
    p
  }
  if s == "/" || s == "" {
    return None
  }
  // Split into segments; drop the last non-empty one.
  let parts : Array[String] = []
  for seg in s.split("/") {
    if seg != "" {
      parts.push(seg.to_owned())
    }
  }
  if parts.is_empty() {
    return None
  }
  ignore(parts.pop()) // drop last segment
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
    // Exists — resolve realpath for dedup, then read.
    let real = self.fs.realpath(candidate) catch {
      _ => return Err("realpath failed for \{candidate}")
    }
    if seen.contains(real) {
      return Ok(None) // already loaded via a symlinked path
    }
    let content = self.fs.read_file(candidate) catch {
      _ => return Err("read_file failed for \{candidate}")
    }
    seen.set(real, ())
    return Ok(Some({ path: real, content }))
  }
  Ok(None)
}

// A missing or unreadable AGENTS.md is normal (many directories have none)
// and must not abort agent construction.

///|
/// Load all context documents for the given cwd. Never raises: every error
/// is converted to a warning and loading continues.
pub async fn ContextLoader::load(
  self : ContextLoader,
  cwd : String,
) -> ContextBundle {
  let warnings : Array[String] = []
  let seen : Map[String, Unit] = Map([])
  // 1. Global: {home}/.cetas/agent/{candidate}
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
  // 2. Ancestors: cwd up to filesystem root. Walk up unconditionally —
  //    context files above the workspace are legitimate (e.g. a monorepo
  //    parent). Root-first ordering: collect in walk order (cwd first),
  //    then reverse so root ends up first.
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
  // walked is cwd-first; reverse to root-first.
  let ancestors : Array[ContextDocument] = []
  for i = walked.length() - 1; i >= 0; i = i - 1 {
    ancestors.push(walked[i])
  }
  { global, ancestors, warnings }
}
