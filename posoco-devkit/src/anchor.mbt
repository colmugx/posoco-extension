///|
/// Workspace anchor: the directory that relative paths in tool calls
/// resolve against. One anchor is built per host from the launch directory
/// and threaded into every tool; the absolute root never appears in
/// model-visible prompts.
pub struct WorkspaceAnchor {
  /// Absolute or process-relative root directory, normalized.
  root : String
} derive(Debug)

///|
/// Build an anchor. `""` normalizes to `"."`; a trailing `/` is dropped
/// (except on `/` itself) so joined paths never contain `//` at the seam.
///
/// ```mbt check
/// test {
///   inspect(
///     WorkspaceAnchor::WorkspaceAnchor("/tmp/proj/").root,
///     content="/tmp/proj",
///   )
/// }
/// ```
pub fn WorkspaceAnchor::WorkspaceAnchor(root : String) -> WorkspaceAnchor {
  // Lexical normalization also drops any trailing "/" (except on "/" itself).
  let root = if root == "" { "." } else { normalize_lexical(root) }
  { root, }
}

///|
/// Resolve `path` against the anchor. Absolute paths pass through
/// unchanged; relative paths are joined onto the root and lexically
/// normalized (`.` and `..` collapse, `//` deduplicates). `..` may rise
/// above the root — containment is a permission concern, not an anchoring
/// one.
///
/// ```mbt check
/// test {
///   let anchor = WorkspaceAnchor::WorkspaceAnchor("/tmp/proj")
///   inspect(anchor.resolve("src/a/../b"), content="/tmp/proj/src/b")
///   inspect(anchor.resolve("../sibling"), content="/tmp/sibling")
/// }
/// ```
pub fn WorkspaceAnchor::resolve(
  self : WorkspaceAnchor,
  path : String,
) -> String {
  if path.has_prefix("/") {
    return path
  }
  normalize_lexical("\{self.root}/\{path}")
}

///|
/// Lexically normalize a joined path: drop `.` and empty segments, apply
/// `..` by popping; `..` above a relative start is retained, above an
/// absolute root it is dropped.
fn normalize_lexical(joined : String) -> String {
  let absolute = joined.has_prefix("/")
  let segments : Array[String] = []
  for seg in joined.split("/") {
    if seg == "" || seg == "." {
      continue
    }
    if seg == ".." {
      if segments.length() > 0 && segments[segments.length() - 1] != ".." {
        ignore(segments.pop())
      } else if !absolute {
        segments.push("..")
      }
      continue
    }
    segments.push(seg.to_owned())
  }
  let body = segments.join("/")
  if absolute {
    "/\{body}"
  } else if body == "" {
    "."
  } else {
    body
  }
}
