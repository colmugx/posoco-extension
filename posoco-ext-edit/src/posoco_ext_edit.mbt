///|
/// EditTools — file editing tool provider (exact string replacement).
///
/// On native, IO via `@fs` (atomic temp+rename). On js (bun), IO via
/// `Bun.file`/`Bun.write` + `move()`. On wasm/wasm-gc, the tool is not
/// listed and execute raises `RuntimeError::InvocationFailed`.
///
/// Match contract: `old_text` must match the file content exactly and —
/// unless `replace_all` is set — uniquely. Ambiguous or missing matches are
/// model-visible `ToolReportedError`s that name the matching line numbers.
/// Line-number prefixes (`L12: `) that the model copied verbatim from read
/// output are stripped from `old_text` when the raw text does not match;
/// this is format hygiene for our own read format, not fuzzy matching.
pub(all) struct EditTools {
  // Shared read-before-modify ledger; None disables the gate (library use).
  freshness : @devkit.FreshnessGuard?
  // Resolves relative paths against the workspace root; None keeps legacy
  // behavior (relative paths land on the process working directory).
  anchor : @devkit.WorkspaceAnchor?
}

///|
/// Canonical constructor. Use this everywhere.
pub fn EditTools::EditTools(
  freshness? : @devkit.FreshnessGuard,
  anchor? : @devkit.WorkspaceAnchor? = None,
) -> EditTools {
  EditTools::{ freshness, anchor }
}

///|
/// File-system IO boundary for the `edit` tool.
///
/// `@fs` is native-only, so each target supplies its own adaptor. The shared
/// `execute_edit_impl` below talks only to this trait.
priv trait FsIo {
  /// Does the file exist? `false` = missing (recoverable); raise = IO error.
  async fn exists(self : Self, path : String) -> Bool raise @posoco.RuntimeError

  /// Stat the file for freshness tracking. Raise = IO error.
  async fn stat(self : Self, path : String) -> @devkit.FileStamp raise @posoco.RuntimeError

  /// Read the entire file as a UTF-8 string. Raise on IO or decode failure.
  async fn read_text(self : Self, path : String) -> String raise @posoco.RuntimeError

  /// Atomically write `content` (temp file + rename). Raise on IO failure.
  async fn write_atomic(self : Self, path : String, content : String) -> Unit raise @posoco.RuntimeError
}

///|
/// Shared tool list for the `edit` tool. Both native and js EditTools expose
/// the same tool definition; only the IO adaptor differs per target.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("edit"),
      description: "Edit a file by exact string replacement: `old_text` is replaced with `new_text`. `old_text` must match the file exactly and, unless `replace_all` is true, must be unique in the file — an ambiguous match is rejected listing the matching line numbers. Line-number prefixes (`L12: `) copied from read output are stripped automatically. The file must have been read in this session and must not have changed since.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "path": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Path to the file to edit"),
          }),
          "old_text": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Exact text to find in the file"),
          }),
          "new_text": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Replacement text"),
          }),
          "replace_all": Json::object({
            "type": Json::string("boolean"),
            "description": Json::string(
              "Replace every occurrence (default: false; a non-unique match without this flag is an error)",
            ),
          }),
        }),
        "required": Json::array([
          Json::string("path"),
          Json::string("old_text"),
          Json::string("new_text"),
        ]),
      }),
      owner: @posoco.OwnerId::unchecked("posoco_ext_edit"),
      policy: @posoco.ExecutionPolicy::Exclusive,
      provenance: Some("posoco_ext_edit"),
    },
  ]
}

///|
/// Extract `(path, old_text, new_text, replace_all)` from ToolCall arguments.
fn extract_edit_args(
  args : Json,
) -> (String, String, String, Bool) raise @posoco.RuntimeError {
  match args {
    Object(obj) => {
      let p = match obj.get("path") {
        Some(String(s)) => s
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "edit: 'path' argument must be a string",
          )
        None => raise @posoco.RuntimeError::UnknownTool("edit: missing 'path'")
      }
      let o = match obj.get("old_text") {
        Some(String(s)) => s
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "edit: 'old_text' argument must be a string",
          )
        None =>
          raise @posoco.RuntimeError::UnknownTool("edit: missing 'old_text'")
      }
      let n = match obj.get("new_text") {
        Some(String(s)) => s
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "edit: 'new_text' argument must be a string",
          )
        None =>
          raise @posoco.RuntimeError::UnknownTool("edit: missing 'new_text'")
      }
      let ra = match obj.get("replace_all") {
        Some(True) => true
        Some(False) | None => false
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "edit: optional 'replace_all' must be a boolean",
          )
      }
      (p, o, n, ra)
    }
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "edit: arguments must be a JSON object",
      )
  }
}

///|
/// Format an `edit` failure RuntimeError with sanitized path.
fn edit_failure(stage : String, path : String) -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "edit: \{stage} failed for '\{@devkit.sanitize_path(path)}'",
  )
}

///|
/// Replace the first occurrence of `old` with `new` in a string.
fn replace_first(text : String, old : String, new : String) -> String {
  match text.find(old) {
    None => text
    Some(pos) => {
      let before = text[0:pos].to_owned()
      let after = text[pos + old.length():].to_owned()
      before + new + after
    }
  }
}

///|
/// All non-overlapping occurrences of `needle` in `content`, as
/// `(absolute char offset, 1-based line number)` pairs, in order.
fn find_occurrences(content : String, needle : String) -> Array[(Int, Int)] {
  let matches : Array[(Int, Int)] = []
  if needle.length() == 0 {
    return matches
  }
  let mut base = 0 // absolute offset the current search window starts at
  let mut counted = 0 // newlines counted up to this absolute offset
  let mut line = 1
  while true {
    match content[base:].find(needle) {
      None => break
      Some(rel) => {
        let abs = base + rel
        while counted < abs {
          if content[counted] == '\n' {
            line += 1
          }
          counted += 1
        }
        matches.push((abs, line))
        base = abs + needle.length()
      }
    }
  }
  matches
}

///|
/// Strip one `L<digits>: ` prefix from a line, if present.
fn strip_line_number_prefix(line : String) -> String? {
  if line.length() < 4 || line[0] != 'L' {
    return None
  }
  let mut i = 1
  while i < line.length() && line[i] >= '0' && line[i] <= '9' {
    i += 1
  }
  if i == 1 || i + 1 >= line.length() {
    return None
  }
  if line[i] == ':' && line[i + 1] == ' ' {
    return Some(line[i + 2:].to_owned())
  }
  None
}

///|
/// Strip `L<n>: ` prefixes from every non-empty line of a block. Returns
/// None unless every non-empty line carries the prefix — the stripped text
/// is only trusted as a whole-block rewrite of our own read format.
fn strip_line_numbers_block(text : String) -> String? {
  let lines = text.split("\n").to_array()
  let stripped : Array[String] = []
  for line in lines {
    match strip_line_number_prefix(line.to_owned()) {
      Some(s) => stripped.push(s)
      None => if line.length() == 0 { stripped.push("") } else { return None }
    }
  }
  Some(stripped.join("\n"))
}

///|
/// Render "line(s) 3, 17, 42" from match lines, capped at five entries.
fn describe_match_lines(lines : Array[Int]) -> String {
  let shown = if lines.length() > 5 { lines[0:5] } else { lines[:] }
  let rendered = [ for l in shown => "\{l}" ].join(", ")
  if lines.length() > 5 {
    "\{rendered}, …"
  } else {
    rendered
  }
}

///|
/// Shared `edit` execute logic. Target-agnostic; only the IO adaptor
/// differs. Uniqueness, prefix stripping, and the freshness gate are
/// business rules that live here.
async fn execute_edit_impl(
  io : &FsIo,
  freshness : @devkit.FreshnessGuard?,
  anchor : @devkit.WorkspaceAnchor?,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let (raw_path, old_text, new_text, all) = extract_edit_args(call.arguments)
  // The resolved path drives IO and the freshness ledger; messages echo the
  // argument as written so the anchor root never leaks into results.
  let path = match anchor {
    Some(anchor) => anchor.resolve(raw_path)
    None => raw_path
  }
  if !io.exists(path) {
    return @posoco.ToolOutcome::ToolReportedError(
      content="File not found: \{@devkit.sanitize_path(raw_path)}",
      structured=None,
    )
  }
  match freshness {
    Some(ledger) => {
      let stamp = io.stat(path)
      match ledger.check(path, Some(stamp)) {
        @devkit.Fresh => ()
        verdict =>
          return @posoco.ToolOutcome::ToolReportedError(
            content="edit: refused: '\{@devkit.sanitize_path(raw_path)}' \{verdict.hint()}",
            structured=None,
          )
      }
    }
    None => ()
  }
  let content = io.read_text(path)
  let mut needle = old_text
  let mut matches = find_occurrences(content, needle)
  let mut stripped = false
  if matches.length() == 0 {
    // Fall back to our own read format: a block whose every non-empty line
    // carries an `L<n>: ` prefix is a verbatim copy of read output.
    match strip_line_numbers_block(old_text) {
      Some(candidate) => {
        let candidate_matches = find_occurrences(content, candidate)
        if candidate_matches.length() > 0 {
          needle = candidate
          matches = candidate_matches
          stripped = true
        }
      }
      None => ()
    }
  }
  if matches.length() == 0 {
    return @posoco.ToolOutcome::ToolReportedError(
      content="edit: old_text not found in \{@devkit.sanitize_path(raw_path)}; the file may have changed since your last read — read it again and retry with the exact current text",
      structured=None,
    )
  }
  let match_lines = [ for m in matches => m.1 ]
  if matches.length() > 1 && !all {
    return @posoco.ToolOutcome::ToolReportedError(
      content="edit: old_text matches \{matches.length()} locations in \{@devkit.sanitize_path(raw_path)} at line(s) \{describe_match_lines(match_lines)}; add surrounding lines to make it unique, or pass replace_all: true",
      structured=None,
    )
  }
  let new_content = if all {
    content.replace_all(old=needle, new=new_text)
  } else {
    replace_first(content, needle, new_text)
  }
  io.write_atomic(path, new_content)
  // The edit changed the stamp: re-record so a follow-up edit of the same
  // file is not rejected as externally modified.
  match freshness {
    Some(ledger) => {
      let stamp = io.stat(path)
      ledger.note_read(path, stamp)
    }
    None => ()
  }
  let occurrence_word = if matches.length() == 1 {
    "occurrence"
  } else {
    "occurrences"
  }
  let line_word = if matches.length() == 1 { "line" } else { "lines" }
  let stripped_note = if stripped {
    " (line-number prefixes stripped from old_text)"
  } else {
    ""
  }
  @posoco.ToolOutcome::Success(
    content="Edited \{@devkit.sanitize_path(raw_path)}: replaced \{matches.length()} \{occurrence_word} at \{line_word} \{describe_match_lines(match_lines)}\{stripped_note}",
    structured=None,
  )
}
