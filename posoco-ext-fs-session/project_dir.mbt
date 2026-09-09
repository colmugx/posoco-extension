///|
/// project_dir.mbt — per-project session bucket naming, shared by both
/// targets. Each project's sessions live in their own directory under
/// `<home>/.cetas/sessions`; the bucket name carries a slug of the cwd's
/// basename plus a short sha256 of the full normalized cwd, so sibling
/// paths like `/a/b_c` and `/a/b/c` (which a slug alone would collide)
/// get distinct buckets.

///|
/// Normalize a cwd for bucket naming: windows separators become `/` and
/// trailing separators are dropped; the root `/` stays itself.
pub fn normalize_cwd(cwd : String) -> String {
  let unified = cwd.replace_all(old="\\", new="/")
  let trimmed = unified.trim_end(chars="/")
  if trimmed.length() == 0 {
    "/"
  } else {
    trimmed.to_owned()
  }
}

///|
/// Final segment of an already-normalized path; the root has no basename.
fn path_basename(normalized : String) -> String {
  if normalized == "/" {
    return ""
  }
  match normalized.rev_find("/") {
    Some(i) => normalized[i + 1:].to_owned()
    None => normalized
  }
}

///|
/// Slug of a project basename: `[a-zA-Z0-9._-]` kept, everything else
/// (spaces, CJK, symbols) replaced with `-`, capped at 40 chars; empty or
/// fully-illegal basenames become the generic `"project"`.
pub fn project_slug(basename : String) -> String {
  let builder = StringBuilder()
  let mut kept = 0
  for ch in basename {
    let code = ch.to_int()
    let ascii_alnum = (code >= 0x61 && code <= 0x7a) ||
      (code >= 0x41 && code <= 0x5a) ||
      (code >= 0x30 && code <= 0x39)
    if ascii_alnum || code == 0x2e || code == 0x5f || code == 0x2d {
      builder.write_char(ch)
      if code != 0x2d {
        kept += 1
      }
    } else {
      builder.write_char('-')
    }
  }
  // A basename with no usable characters (empty, all-illegal, bare
  // separators) gets the generic name so buckets stay readable.
  if kept == 0 {
    return "project"
  }
  let slug = builder.to_string()
  // The map above keeps only ASCII, so code-unit length is char length.
  if slug.length() > 40 {
    return slug.sub(start=0, end=40).to_owned()
  }
  slug
}

///|
/// First 12 hex chars of sha256 over the UTF-8 bytes of the cwd: the
/// collision guard for projects whose basenames slug to the same string.
fn cwd_fingerprint(normalized : String) -> String {
  let hex = @crypto.bytes_to_hex_string(
    @crypto.sha256(@utf8.encode(normalized)),
  )
  hex.sub(start=0, end=12).to_owned()
}

///|
/// Bucket directory name for a cwd: `session_<slug(basename)>_<sha256[0..12]>`.
pub fn project_dir_name(cwd : String) -> String {
  let normalized = normalize_cwd(cwd)
  "session_" +
  project_slug(path_basename(normalized)) +
  "_" +
  cwd_fingerprint(normalized)
}

///|
/// Session root for one project: `<home>/.cetas/sessions/<project_dir_name>`.
pub fn project_sessions_dir(home : String, cwd : String) -> String {
  home + "/.cetas/sessions/" + project_dir_name(cwd)
}

///|
/// Store bound to one project's bucket directory.
pub fn JsonlSessionStore::of_project(
  home~ : String,
  cwd~ : String,
) -> JsonlSessionStore {
  JsonlSessionStore::JsonlSessionStore(project_sessions_dir(home, cwd))
}
