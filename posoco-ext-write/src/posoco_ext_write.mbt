///|
/// WriteTools — file writing tool provider.
///
/// On native, writes via `@fs` (atomic temp+rename, parent dirs created).
/// On js (bun), writes via `Bun.write` + `Bun.file().move()` rename. On
/// wasm/wasm-gc, the tool is not listed and execute raises
/// `RuntimeError::InvocationFailed`.
///
/// Modification contract: writing an existing file requires that the file
/// was read earlier in the same agent (via a shared `FreshnessGuard`) and
/// has not changed since; a violation is a `ToolReportedError` so the model
/// can re-read and retry instead of losing the turn. A successful write
/// records the new stamp, so follow-up edits are not blocked by the write
/// itself.
pub(all) struct WriteTools {
  // Shared read-before-modify ledger; None disables the gate (library use).
  freshness : @devkit.FreshnessGuard?
  // Resolves relative paths against the workspace root; None keeps legacy
  // behavior (relative paths land on the process working directory).
  anchor : @devkit.WorkspaceAnchor?
}

///|
/// Canonical constructor. Use this everywhere.
pub fn WriteTools::WriteTools(
  freshness? : @devkit.FreshnessGuard,
  anchor? : @devkit.WorkspaceAnchor? = None,
) -> WriteTools {
  WriteTools::{ freshness, anchor, }
}

///|
/// Max content size accepted by one write call.
const WRITE_MAX_BYTES = 1_000_000

///|
/// File-system IO boundary for the `write` tool.
///
/// `@fs` is native-only, so each target supplies its own adaptor. The shared
/// `execute_write_impl` below talks only to this trait, keeping the business
/// rules (freshness gate, size cap, result shape) in one place.
priv trait FsIo {
  /// Does the target path exist? `false` = missing; raise = IO error.
  async fn exists(self : Self, path : String) -> Bool raise @posoco.RuntimeError

  /// Stat the file for freshness tracking. Raise = IO error.
  async fn stat(self : Self, path : String) -> @devkit.FileStamp raise @posoco.RuntimeError

  /// Atomically write `content` (temp file + rename), creating parent
  /// directories as needed. Raise = IO error.
  async fn write_atomic(self : Self, path : String, content : String) -> Unit raise @posoco.RuntimeError
}

///|
/// Shared tool list for the `write` tool. Both native and js WriteTools
/// expose the same tool definition; only the IO adaptor differs per target.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("write"),
      description: "Write text content to a file. Creates the file if it does not exist (including parent directories); atomically replaces it if it does. Use write for new files or complete rewrites; use edit for targeted changes. If the file already exists, it must have been read in this session and must not have changed since.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "path": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Path to the file to write"),
          }),
          "content": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Text content to write"),
          }),
        }),
        "required": Json::array([Json::string("path"), Json::string("content")]),
      }),
      owner: @posoco.OwnerId::unchecked("posoco_ext_write"),
      policy: @posoco.ExecutionPolicy::Exclusive,
      provenance: Some("posoco_ext_write"),
    },
  ]
}

///|
/// Extract `(path, content)` from ToolCall arguments.
fn extract_path_content(
  args : Json,
) -> (String, String) raise @posoco.RuntimeError {
  match args {
    Object(obj) => {
      let p = match obj.get("path") {
        Some(String(s)) => s
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "write: 'path' argument must be a string",
          )
        None => raise @posoco.RuntimeError::UnknownTool("write: missing 'path'")
      }
      let c = match obj.get("content") {
        Some(String(s)) => s
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "write: 'content' argument must be a string",
          )
        None =>
          raise @posoco.RuntimeError::UnknownTool("write: missing 'content'")
      }
      (p, c)
    }
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "write: arguments must be a JSON object",
      )
  }
}

///|
/// Format a `write` failure RuntimeError with sanitized path.
fn write_failure(stage : String, path : String) -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "write: \{stage} failed for '\{@devkit.sanitize_path(path)}'",
  )
}

///|
/// Parent directory of `path` ("" and "." both mean cwd; "/" stays root).
fn parent_dir(path : String) -> String {
  match path.rev_find("/") {
    Some(0) => "/"
    Some(pos) if pos > 0 => path[:pos].to_owned()
    _ => "."
  }
}

///|
/// Shared `write` execute logic. Target-agnostic; only the IO adaptor
/// differs. The freshness gate rejects (as a model-visible tool error, not
/// a runtime failure) any overwrite of an existing file that was not read
/// in this session or that changed since its last read.
async fn execute_write_impl(
  io : &FsIo,
  freshness : @devkit.FreshnessGuard?,
  anchor : @devkit.WorkspaceAnchor?,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let (raw_path, content) = extract_path_content(call.arguments)
  // The resolved path drives IO and the freshness ledger; messages echo the
  // argument as written so the anchor root never leaks into results.
  let path = match anchor {
    Some(anchor) => anchor.resolve(raw_path)
    None => raw_path
  }
  let content_bytes = @utf8.encode(content).length()
  if content_bytes > WRITE_MAX_BYTES {
    return @posoco.ToolOutcome::ToolReportedError(
      content="write: refused: content is \{content_bytes} bytes; the cap is \{WRITE_MAX_BYTES} bytes",
      structured=None,
    )
  }
  match freshness {
    Some(ledger) =>
      if io.exists(path) {
        let stamp = io.stat(path)
        match ledger.check(path, Some(stamp)) {
          @devkit.Fresh => ()
          verdict =>
            return @posoco.ToolOutcome::ToolReportedError(
              content="write: refused: '\{@devkit.sanitize_path(raw_path)}' \{verdict.hint()}",
              structured=None,
            )
        }
      }
    None => ()
  }
  io.write_atomic(path, content)
  // The write itself changed the stamp: re-record so a follow-up edit is not
  // rejected as externally modified. The writer obviously knows the content.
  match freshness {
    Some(ledger) =>
      if io.exists(path) {
        let stamp = io.stat(path)
        ledger.note_read(path, stamp)
      }
    None => ()
  }
  @posoco.ToolOutcome::Success(
    content="Wrote \{content_bytes} bytes to \{@devkit.sanitize_path(raw_path)}",
    structured=None,
  )
}
