///|
/// WorkspacePolicy — the single boundary all workspace operations pass through.
///
/// The policy is pure data; it does not perform IO. Path resolvers and tools
/// use the policy to validate paths before touching the filesystem.
///
/// Enforces:
/// - root containment (lexical + resolved)
/// - cwd containment
/// - symlink safety (target must also be in root)
/// - read/write capability flags
/// - ignore patterns
/// - resource limits (bytes, depth, entries, matches)

// ──────────────────────────────────────────────────────────────────────────
// Symlink policy
// ──────────────────────────────────────────────────────────────────────────

///|
/// How symlinks are treated during path resolution.
pub(all) enum SymlinkPolicy {
  /// Reject any symlink — safest; never follow links.
  Reject
  /// Follow symlinks but the resolved target MUST remain inside root.
  /// If the target escapes root, the operation is rejected.
  FollowIfInsideRoot
} derive(Eq, Debug)

// ──────────────────────────────────────────────────────────────────────────
// Capability flags
// ──────────────────────────────────────────────────────────────────────────

///|
/// Read/write capability for the workspace.
pub(all) struct Capability {
  read : Bool
  write : Bool
} derive(Debug)

///|
pub fn Capability::read_only() -> Capability {
  { read: true, write: false }
}

///|
pub fn Capability::read_write() -> Capability {
  { read: true, write: true }
}

// ──────────────────────────────────────────────────────────────────────────
// Resource limits
// ──────────────────────────────────────────────────────────────────────────

///|
/// Bounded-work limits. Frozen defaults from the adapter reliability
/// contract; configurable per-policy.
pub(all) struct WorkspaceLimits {
  max_read_bytes : Int
  max_walk_depth : Int
  max_walk_entries : Int
  max_results : Int // glob/grep/find/ls result count
  max_matches_per_file : Int // grep
  max_line_width : Int // grep line truncation
} derive(Debug)

///|
/// Default limits.
pub fn WorkspaceLimits::defaults() -> WorkspaceLimits {
  {
    max_read_bytes: 65536,
    max_walk_depth: 32,
    max_walk_entries: 100000,
    max_results: 1000,
    max_matches_per_file: 1000,
    max_line_width: 1024,
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Path policy errors
// ──────────────────────────────────────────────────────────────────────────

///|
pub(all) suberror PathPolicyError {
  LexicalEscape(rule~ : String, relative~ : String)
  CwdEscape(rule~ : String, relative~ : String)
  SymlinkEscape(rule~ : String, relative~ : String)
  SymlinkLoop(rule~ : String, relative~ : String)
  AbsolutePathRejected(rule~ : String, relative~ : String)
  ReadDenied(rule~ : String, relative~ : String)
  WriteDenied(rule~ : String, relative~ : String)
  ParentCreationDenied(rule~ : String, relative~ : String)
} derive(Eq, Debug)

// ──────────────────────────────────────────────────────────────────────────
// The policy itself
// ──────────────────────────────────────────────────────────────────────────

///|
/// The unified workspace boundary. Constructed once per workspace;
/// shared by all consumers.
pub(all) struct WorkspacePolicy {
  /// Absolute filesystem root. All resolved paths must be inside this.
  root : String
  /// Default working directory (must be inside root). Relative paths
  /// in tool calls resolve against this.
  default_cwd : String
  /// Read/write capability.
  capability : Capability
  /// Symlink handling.
  symlink : SymlinkPolicy
  /// Glob patterns to ignore during traversal (e.g. ["node_modules", ".git"]).
  ignore_patterns : Array[String]
  /// Resource limits.
  limits : WorkspaceLimits
  /// Whether to allow creating parent directories on write/edit.
  /// Default false — must be explicitly allowed.
  allow_create_parent : Bool
} derive(Debug)

///|
/// Build a workspace policy with root + cwd, using safe defaults.
/// Raises if cwd is not inside root.
pub fn WorkspacePolicy::new(
  root~ : String,
  default_cwd? : String = "",
  capability? : Capability = Capability::read_write(),
  symlink? : SymlinkPolicy = FollowIfInsideRoot,
  ignore_patterns? : Array[String] = [
    "node_modules", ".git", ".hg", ".svn", "_build", "target",
  ],
  limits? : WorkspaceLimits = WorkspaceLimits::defaults(),
  allow_create_parent? : Bool = false,
) -> Result[WorkspacePolicy, String] {
  let cwd = if default_cwd == "" { root } else { default_cwd }
  // Lexical check: cwd must start with root.
  if !is_lexically_inside(cwd, root) {
    return Err("default_cwd '\{cwd}' is not inside root '\{root}'")
  }
  Ok({
    root,
    default_cwd: cwd,
    capability,
    symlink,
    ignore_patterns,
    limits,
    allow_create_parent,
  })
}

// ──────────────────────────────────────────────────────────────────────────
// Pure lexical path checks (no IO)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Lexical check: is `path` inside `root`? Normalizes `..` first.
/// This is the first line of defense; a resolver also checks the
/// resolved (canonicalized) target.
pub fn is_lexically_inside(path : String, root : String) -> Bool {
  let normalized = normalize_lexical(path)
  let normalized_root = normalize_lexical(root)
  if normalized == normalized_root {
    return true
  }
  // path must be root + "/" + something, with no `..` escaping.
  normalized.has_prefix(normalized_root + "/")
}

///|
/// Normalize a path lexically: resolve `.`, `..`, collapse `//`.
/// Does NOT touch the filesystem.
pub fn normalize_lexical(path : String) -> String {
  let parts : Array[String] = []
  let is_absolute = path.has_prefix("/")
  for seg in path.split("/") {
    match seg {
      "" | "." => continue
      ".." => ignore(parts.pop())
      s => parts.push(s.to_owned())
    }
  }
  let joined = parts.join("/")
  if is_absolute {
    "/" + joined
  } else if joined == "" {
    "."
  } else {
    joined
  }
}

///|
/// Does `path` match any ignore pattern? A pattern matches if:
/// - the path equals the pattern, OR
/// - the path starts with `pattern + "/"` (directory prefix match), OR
/// - any path segment equals the pattern (matches nested dirs too).
/// This mirrors `.gitignore` semantics for directory-name patterns.
pub fn matches_ignore(path : String, patterns : Array[String]) -> Bool {
  for pat in patterns {
    // Exact match
    if path == pat {
      return true
    }
    // Directory prefix: pattern "node_modules" matches "node_modules/foo"
    if path.has_prefix(pat + "/") {
      return true
    }
    // Any path segment equals the pattern (matches nested dirs too)
    for seg in path.split("/") {
      if seg == pat {
        return true
      }
    }
  }
  false
}

///|
/// Simple glob matcher supporting `*` (within a segment) and `**` (across `/`).
/// Used for ignore patterns.
pub fn glob_match(pattern : String, text : String) -> Bool {
  let p = pattern.split("/").to_array()
  let t = text.split("/").to_array()
  glob_match_segments(p, 0, t, 0)
}

///|
fn glob_match_segments(
  p : Array[StringView],
  pi : Int,
  t : Array[StringView],
  ti : Int,
) -> Bool {
  if pi >= p.length() {
    return ti >= t.length()
  }
  if p[pi] == "**" {
    // ** matches zero or more segments
    for skip in ti..<=t.length() {
      if glob_match_segments(p, pi + 1, t, skip) {
        return true
      }
    }
    return false
  }
  if ti >= t.length() {
    return false
  }
  if segment_match(p[pi], t[ti]) {
    return glob_match_segments(p, pi + 1, t, ti + 1)
  }
  false
}

///|
/// Match a single path segment against a pattern segment (with `*`).
fn segment_match(pat : StringView, seg : StringView) -> Bool {
  // Convert to char arrays for wildcard matching.
  let pat_chars = pat.to_owned().to_array()
  let seg_chars = seg.to_owned().to_array()
  wildcard_match(pat_chars, 0, seg_chars, 0)
}

///|
fn wildcard_match(
  pat : Array[Char],
  pi : Int,
  seg : Array[Char],
  si : Int,
) -> Bool {
  if pi >= pat.length() {
    return si >= seg.length()
  }
  if pat[pi] == '*' {
    // * matches zero or more chars within the segment
    for skip in si..<=seg.length() {
      if wildcard_match(pat, pi + 1, seg, skip) {
        return true
      }
    }
    return false
  }
  if si >= seg.length() {
    return false
  }
  if pat[pi] == seg[si] {
    return wildcard_match(pat, pi + 1, seg, si + 1)
  }
  false
}
