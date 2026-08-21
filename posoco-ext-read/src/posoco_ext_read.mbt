///|
/// ReadTools — file reading tool provider.
///
/// On native, reads via `@fs` with line streaming (lines before `offset` are
/// never materialized). On js (bun), reads via `Bun.file`. On wasm/wasm-gc,
/// the tool is not listed and execute raises `RuntimeError::InvocationFailed`.
///
/// Output contract: lines are prefixed `L<line>: ` (1-indexed, no padding),
/// long lines are truncated at 2000 characters with a marker, and reads cut
/// by the line/byte caps end with a footer naming the next offset. Successful
/// reads record a `FileStamp` in the injected `FreshnessGuard` (if any) so
/// the write/edit tools can refuse stale modifications.
pub(all) struct ReadTools {
  // Shared read-before-modify ledger; None disables recording (library use).
  freshness : @devkit.FreshnessGuard?
}

///|
/// Canonical constructor. Use this everywhere to avoid cross-target naming
/// drift. `guard` is optional: without it the tool still reads, it just does
/// not participate in freshness tracking.
pub fn ReadTools::ReadTools(freshness? : @devkit.FreshnessGuard) -> ReadTools {
  ReadTools::{ freshness, }
}

///|
/// Default max lines per read (kimi-code parity).
const READ_DEFAULT_LIMIT = 1000

///|
/// Max characters per output line before truncation (char-boundary safe).
const READ_LINE_CHAR_CAP = 2000

///|
/// Max formatted bytes per read result before the page is cut.
const READ_BYTE_CAP = 100_000

///|
/// A window of lines plus file totals. `lines` carries normalized text
/// (no newline terminators, trailing `\r` stripped); `total_lines` counts
/// every line in the file so callers can render "N more lines" footers.
priv struct LinePage {
  lines : Array[String]
  total_lines : Int
  total_bytes : Int64
}

///|
/// File-system IO boundary for the `read` tool.
///
/// `@fs` is native-only, so each target supplies its own adaptor. The shared
/// `execute_read_impl` below talks only to this trait, keeping the business
/// rules (paging, caps, formatting, freshness) in one place.
priv trait FsIo {
  /// Does the file exist? `false` = missing (recoverable); raise = IO error.
  async fn exists(self : Self, path : String) -> Bool raise @posoco.RuntimeError

  /// Stat the file for freshness tracking. Raise = IO error.
  async fn stat(self : Self, path : String) -> @devkit.FileStamp raise @posoco.RuntimeError

  /// Return the 0-based window `[skip, skip+take)` of lines. Adaptors must
  /// count every line in the file (streaming on native) even past the window.
  async fn read_lines(self : Self, path : String, skip : Int, take : Int) -> LinePage raise @posoco.RuntimeError

  /// Return the last `take` lines of the file (tail window).
  async fn read_last_lines(self : Self, path : String, take : Int) -> LinePage raise @posoco.RuntimeError
}

///|
/// Shared tool list for the `read` tool. Both native and js ReadTools expose
/// the same tool definition; only the IO adaptor differs per target.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("read"),
      description: "Read a file's contents with `L<line>: ` line-numbered lines. Optional `offset` is the 1-indexed line to start from; a negative offset reads the last |offset| lines of the file. Optional `limit` caps the lines returned (default 1000). Lines longer than 2000 characters are truncated with a marker; when the result is cut short a footer reports how many lines remain and the offset to continue from. Reads record file state so write/edit can detect external changes.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "path": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Path to the file to read"),
          }),
          "offset": Json::object({
            "type": Json::string("integer"),
            "description": Json::string(
              "1-indexed line number to start from; negative counts back from the end of the file",
            ),
          }),
          "limit": Json::object({
            "type": Json::string("integer"),
            "description": Json::string(
              "Maximum number of lines to return (default 1000)",
            ),
          }),
        }),
        "required": Json::array([Json::string("path")]),
      }),
      owner: @posoco.OwnerId::unchecked("posoco_ext_read"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some("posoco_ext_read"),
    },
  ]
}

///|
/// Extract `(path, offset?, limit?)` from ToolCall arguments. Typed errors on
/// wrong types; value validation (nonzero offset, positive limit) happens in
/// `execute_read_impl` so those messages live next to the paging logic.
fn extract_read_args(
  args : Json,
) -> (String, Int?, Int?) raise @posoco.RuntimeError {
  match args {
    Object(obj) => {
      let path = match obj.get("path") {
        Some(String(p)) => p
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "read: 'path' argument must be a string",
          )
        None => raise @posoco.RuntimeError::UnknownTool("read: missing 'path'")
      }
      let offset = match obj.get("offset") {
        Some(Number(n, ..)) => Some(n.to_int())
        Some(Null) | None => None
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "read: optional 'offset' must be an integer",
          )
      }
      let limit = match obj.get("limit") {
        Some(Number(n, ..)) => Some(n.to_int())
        Some(Null) | None => None
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "read: optional 'limit' must be an integer",
          )
      }
      (path, offset, limit)
    }
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "read: arguments must be a JSON object",
      )
  }
}

///|
/// Format a `read` failure RuntimeError with sanitized path.
fn read_failure(stage : String, path : String) -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "read: \{stage} failed for '\{@devkit.sanitize_path(path)}'",
  )
}

///|
/// Strip one trailing `\r` left by CRLF line endings.
fn strip_trailing_cr(s : String) -> String {
  if s.length() > 0 && s[s.length() - 1] == '\r' {
    s[:s.length() - 1].to_owned()
  } else {
    s
  }
}

///|
/// Truncate `s` to at most `cap` characters, cutting at a char boundary.
fn truncate_chars(s : String, cap : Int) -> String {
  if s.length() <= cap {
    return s
  }
  let out = StringBuilder::new()
  let mut count = 0
  for c in s {
    if count == cap {
      break
    }
    out.write_char(c)
    count += 1
  }
  out.to_string()
}

///|
/// Render up to `cap_bytes` of `L<n>: ` formatted lines.
///
/// Returns the body, the number of lines actually returned, and whether the
/// byte cap cut the page short. Line truncation markers and the `L<n>: `
/// prefix count toward the byte budget so the result is bounded by
/// `cap_bytes` plus one final line.
fn format_read_page(
  lines : Array[String],
  start_line : Int,
  cap_bytes : Int,
) -> (String, Int, Bool) {
  let out = StringBuilder::new()
  let mut returned = 0
  let mut bytes = 0
  let mut byte_cut = false
  for i, raw in lines {
    let rendered = if raw.length() > READ_LINE_CHAR_CAP {
      "L\{start_line + i}: \{truncate_chars(raw, READ_LINE_CHAR_CAP)} … (line truncated)"
    } else {
      "L\{start_line + i}: \{raw}"
    }
    let line_bytes = @utf8.encode(rendered).length()
    if returned > 0 && bytes + line_bytes > cap_bytes {
      byte_cut = true
      break
    }
    if returned > 0 {
      out.write_char('\n')
    }
    out.write_string(rendered)
    bytes += line_bytes
    returned += 1
  }
  (out.to_string(), returned, byte_cut)
}

///|
/// Shared `read` execute logic. Target-agnostic; only the IO adaptor differs.
async fn execute_read_impl(
  io : &FsIo,
  freshness : @devkit.FreshnessGuard?,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let (path, offset_opt, limit_opt) = extract_read_args(call.arguments)
  match offset_opt {
    Some(0) =>
      raise @posoco.RuntimeError::UnknownTool(
        "read: 'offset' must be a nonzero 1-indexed line number; negative counts back from the end",
      )
    _ => ()
  }
  match limit_opt {
    Some(l) if l <= 0 =>
      raise @posoco.RuntimeError::UnknownTool(
        "read: 'limit' must be greater than zero",
      )
    _ => ()
  }
  // exists() returns false for a missing file (recoverable → message);
  // it raises RuntimeError only on a genuine IO error (permission, etc).
  if !io.exists(path) {
    return @posoco.ToolOutcome::ToolReportedError(
      content="File not found: \{@devkit.sanitize_path(path)}",
      structured=None,
    )
  }
  let stamp = io.stat(path)
  let limit = match limit_opt {
    Some(l) => l
    None => READ_DEFAULT_LIMIT
  }
  let explicit_range = offset_opt is Some(_) || limit_opt is Some(_)
  let (page, start_line) = match offset_opt {
    None | Some(1) => {
      let p = io.read_lines(path, 0, limit)
      (p, 1)
    }
    Some(n) if n > 1 => {
      let p = io.read_lines(path, n - 1, limit)
      (p, n)
    }
    Some(n) => {
      // Negative offset: the last |n| lines, capped by limit.
      let take = if -n < limit { -n } else { limit }
      let p = io.read_last_lines(path, take)
      let start = p.total_lines - p.lines.length() + 1
      (p, start)
    }
  }
  if page.total_lines == 0 {
    let content = "(file exists but is empty)"
    match freshness {
      Some(g) => g.note_read(path, stamp)
      None => ()
    }
    return @posoco.ToolOutcome::Success(content~, structured=None)
  }
  if offset_opt is Some(n) && n > 1 && n > page.total_lines {
    return @posoco.ToolOutcome::ToolReportedError(
      content="offset \{n} is past the end of the file; the file has \{page.total_lines} lines",
      structured=None,
    )
  }
  let (body, returned, byte_cut) = format_read_page(
    page.lines,
    start_line,
    READ_BYTE_CAP,
  )
  if byte_cut && explicit_range {
    raise @posoco.RuntimeError::InvocationFailed(
      "read: requested range for '\{@devkit.sanitize_path(path)}' exceeds the \{READ_BYTE_CAP} byte output cap; use a smaller limit or grep for the specific content",
    )
  }
  let end_line = start_line + returned - 1
  let more = page.total_lines - end_line
  let mut content = body
  if byte_cut || more > 0 {
    content = "\{content}\n… \{more} more lines; call read with offset=\{end_line + 1}"
  }
  match freshness {
    Some(g) => g.note_read(path, stamp)
    None => ()
  }
  @posoco.ToolOutcome::Success(
    content~,
    structured=Some(
      Json::object({
        "path": Json::string(path),
        "start_line": Json::number(start_line.to_double()),
        "end_line": Json::number(end_line.to_double()),
        "total_lines": Json::number(page.total_lines.to_double()),
        "returned_lines": Json::number(returned.to_double()),
        "truncated": Json::boolean(byte_cut || more > 0),
      }),
    ),
  )
}
