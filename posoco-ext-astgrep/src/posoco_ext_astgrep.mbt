///|
/// AstGrepTools — structural (AST) code-search tool provider.
///
/// The `astgrep` tool searches code by syntactic shape using ast-grep
/// patterns (meta-variables like `$NAME` / `$$$BODY`), not by literal text —
/// unlike the grep extension's literal search. On native the binary is
/// spawned through `@process`; on js (bun) through the Bun spawn envelope.
/// Both backends probe `ast-grep` / `sg` candidates with a `--version`
/// banner check; when no real binary is found, execute raises
/// `RuntimeError::InvocationFailed` with an install hint (there is no
/// in-process fallback). On wasm-gc the tool is not listed and execute
/// raises the same error.
pub(all) struct AstGrepTools {
  // Resolves the search base against the workspace root; None keeps legacy
  // behavior (the base lands on the process working directory).
  anchor : @devkit.WorkspaceAnchor?
}

///|
/// Canonical constructor.
pub fn AstGrepTools::AstGrepTools(
  anchor? : @devkit.WorkspaceAnchor? = None,
) -> AstGrepTools {
  AstGrepTools::{ anchor, }
}

///|
/// Default number of matches returned to the model.
const ASTGREP_DEFAULT_MAX_MATCHES = 100

///|
/// Keep each structural hit as a locator/excerpt, not a full matched subtree.
const ASTGREP_MATCH_CHAR_CAP = 500

///|
/// Hard body budget. The short truncation footer rides above this cap.
const ASTGREP_OUTPUT_BYTE_CAP = 32_000

///|
/// Error diagnostics need much less context than successful search results.
const ASTGREP_ERROR_CHAR_CAP = 4_000

///|
/// One parsed tool-call query: the ast-grep pattern plus optional filters.
priv struct AstGrepQuery {
  pattern : String
  lang : String?
  path : String?
  glob : String?
  max_matches : Int
}

///|
/// Target seam: run one ast-grep argv (the binary itself is the backend's
/// probe winner), returning `(exit_code, stdout, stderr)`. Backends
/// implement only this; probe + argv + rendering stay in the shared impl.
priv trait AstGrepSpawn {
  async fn spawn(self : Self, argv : Array[String]) -> (Int, String, String) raise @posoco.RuntimeError
}

///|
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("astgrep"),
      description: "Structural code search with ast-grep patterns and meta-variables. Returns compact file/line excerpts.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "pattern": Json::object({
            "type": Json::string("string"),
            "description": Json::string(
              "AST pattern; supports $NAME and $$$BODY meta-variables",
            ),
          }),
          "lang": Json::object({
            "type": Json::string("string"),
            "description": Json::string(
              "Language id (e.g. ts, py); inferred when omitted",
            ),
          }),
          "path": Json::object({
            "type": Json::string("string"),
            "description": Json::string("File or directory; default '.'"),
          }),
          "glob": Json::object({
            "type": Json::string("string"),
            "description": Json::string("File glob, e.g. '*.ts'"),
          }),
          "max_matches": Json::object({
            "type": Json::string("integer"),
            "description": Json::string("Returned match cap; default 100"),
          }),
        }),
        "required": Json::array([Json::string("pattern")]),
      }),
      owner: @posoco.OwnerId::unchecked("posoco_ext_astgrep"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some("posoco_ext_astgrep"),
    },
  ]
}

///|
/// Extract the ast-grep query from ToolCall arguments. Validation failures
/// return a model-visible fix hint instead of raising; the caller turns it
/// into a `ToolReportedError`.
fn extract_astgrep_args(args : Json) -> Result[AstGrepQuery, String] {
  let obj = match args {
    Object(obj) => obj
    _ => return Err("astgrep: arguments must be an object")
  }
  let pattern = match obj.get("pattern") {
    Some(String(s)) =>
      if s == "" {
        return Err("astgrep: 'pattern' must be non-empty")
      } else {
        s
      }
    Some(_) => return Err("astgrep: 'pattern' must be a string")
    None => return Err("astgrep: missing 'pattern'")
  }
  let lang = match obj.get("lang") {
    Some(String(s)) => Some(s)
    None | Some(Null) => None
    Some(_) => return Err("astgrep: 'lang' must be a string")
  }
  let path = match obj.get("path") {
    Some(String(s)) => Some(s)
    None | Some(Null) => None
    Some(_) => return Err("astgrep: 'path' must be a string")
  }
  let glob = match obj.get("glob") {
    Some(String(s)) => Some(s)
    None | Some(Null) => None
    Some(_) => return Err("astgrep: 'glob' must be a string")
  }
  let max_matches = match obj.get("max_matches") {
    None | Some(Null) => ASTGREP_DEFAULT_MAX_MATCHES
    Some(Number(n, ..)) => {
      let value = n.to_int()
      if value <= 0 {
        return Err("astgrep: 'max_matches' must be > 0")
      }
      value
    }
    Some(_) => return Err("astgrep: 'max_matches' must be an integer")
  }
  Ok(AstGrepQuery::{ pattern, lang, path, glob, max_matches, })
}

///|
/// Pure ast-grep argv builder: `run -p <pattern>` plus optional `-l`,
/// `--globs`, and a trailing positional path (omitted when empty). The
/// binary name is not part of the argv; the backend owns its probe winner.
fn build_astgrep_args(
  pattern : String,
  lang : String?,
  path : String?,
  glob : String?,
) -> Array[String] {
  let args : Array[String] = ["run", "-p", pattern, "--json=stream"]
  match lang {
    Some(lang) => {
      args.push("-l")
      args.push(lang)
    }
    None => ()
  }
  match glob {
    Some(glob) => {
      args.push("--globs")
      args.push(glob)
    }
    None => ()
  }
  match path {
    Some(path) => if path != "" { args.push(path) }
    None => ()
  }
  args
}

///|
/// Install hint for a machine without ast-grep, listing every candidate the
/// probe tried so the operator can see what was searched.
fn missing_binary_error(candidates : Array[String]) -> String {
  "astgrep: binary not found (tried: \{candidates.join(", ")}). Install ast-grep, e.g. `brew install ast-grep`, then retry."
}

///|
/// One parsed ast-grep JSON-stream match. ast-grep reports zero-based lines;
/// the model-facing contract uses one-based lines like the read/grep tools.
priv struct AstGrepMatch {
  file : String
  line : Int
  text : String
}

///|
fn astgrep_structured(count : Int, returned : Int) -> Json {
  Json::object(
    Map::from_array([
      ("summary", Json::string("\{count} matches")),
      ("count", Json::number(count.to_double())),
      ("returned", Json::number(returned.to_double())),
      ("truncated", Json::boolean(returned < count)),
    ]),
  )
}

///|
fn astgrep_parse_match(line : String) -> AstGrepMatch? {
  let parsed = @json.parse(line) catch { _ => return None }
  match parsed {
    {
      "file": String(file),
      "text": String(text),
      "range": { "start": { "line": Number(line, ..), .. }, .. },
      ..
    } => Some({ file, line: line.to_int() + 1, text, })
    _ => None
  }
}

///|
/// One-line locator excerpt. Search should locate code; callers can use read
/// for full context. Flatten multi-line subtrees and cap each excerpt.
fn astgrep_excerpt(text : String) -> String {
  let flat = text.replace_all(old="\r", new=" ").replace_all(old="\n", new=" ")
  let clipped = @devkit.truncate_chars(flat, ASTGREP_MATCH_CHAR_CAP)
  if clipped == flat {
    clipped
  } else {
    clipped + "…"
  }
}

///|
/// Render grouped file/line excerpts under both an entry cap and a body byte
/// cap. Returns body, shown count, and total parsed match count.
fn astgrep_render_stream(
  stdout : String,
  max_matches : Int,
) -> (String, Int, Int)? {
  let matches : Array[AstGrepMatch] = []
  for view in stdout.split("\n") {
    if view == "" {
      continue
    }
    let line = view.to_owned()
    match astgrep_parse_match(line) {
      Some(item) => matches.push(item)
      None => return None
    }
  }
  if matches.is_empty() {
    return Some(("", 0, 0))
  }
  let out = StringBuilder()
  let mut shown = 0
  let mut bytes = 0
  let mut last_file = ""
  for item in matches {
    if shown >= max_matches {
      break
    }
    let file = @devkit.sanitize_path(item.file)
    let prefix = if file == last_file { "" } else { file + "\n" }
    let record = prefix +
      item.line.to_string() +
      "|" +
      astgrep_excerpt(item.text) +
      "\n"
    let record_bytes = @utf8.encode(record).length()
    if shown > 0 && bytes + record_bytes > ASTGREP_OUTPUT_BYTE_CAP {
      break
    }
    out.write_string(record)
    bytes += record_bytes
    shown += 1
    last_file = file
  }
  Some((out.to_string(), shown, matches.length()))
}

///|
fn astgrep_bounded_raw(text : String, limit : Int) -> String {
  let clipped = @devkit.truncate_chars(text, limit)
  if clipped == text {
    clipped
  } else {
    clipped + "\n…[cut]"
  }
}

///|
/// Turn one spawn result into the tool outcome. Successful searches consume
/// ast-grep's documented JSON-stream output and expose only compact locators
/// and excerpts. Unexpected JSON falls back to bounded raw output rather than
/// failing a valid search. Errors are independently capped.
fn render_astgrep_result(
  exit_code : Int,
  stdout : String,
  stderr : String,
  base : String,
  max_matches : Int,
) -> @posoco.ToolOutcome {
  if exit_code == 0 {
    if stdout == "" {
      return @posoco.ToolOutcome::Success(
        content="(no matches)",
        structured=Some(astgrep_structured(0, 0)),
      )
    }
    match astgrep_render_stream(stdout, max_matches) {
      Some((body, shown, total)) => {
        let footer = if shown < total {
          "… +\{total - shown} matches"
        } else {
          ""
        }
        let content = if footer == "" {
          body.trim_end(chars="\n").to_owned()
        } else if body == "" {
          footer
        } else {
          body + footer
        }
        @posoco.ToolOutcome::Success(
          content~,
          structured=Some(astgrep_structured(total, shown)),
        )
      }
      None =>
        @posoco.ToolOutcome::Success(
          content=astgrep_bounded_raw(stdout, ASTGREP_OUTPUT_BYTE_CAP),
          structured=None,
        )
    }
  } else {
    let detail = if stderr != "" { stderr } else { stdout }
    let detail = astgrep_bounded_raw(detail, ASTGREP_ERROR_CHAR_CAP)
    let path = @devkit.sanitize_path(base)
    @posoco.ToolOutcome::ToolReportedError(
      content="astgrep exit=\{exit_code} path=\{path}\n\{detail}",
      structured=None,
    )
  }
}

///|
/// Shared `astgrep` execute logic. Target-agnostic; the spawner owns the
/// probe and process IO. When anchored, the search base resolves against
/// the workspace root (default base: the anchor root), and backends run the
/// child with the root as its working directory; otherwise the base lands
/// on the process working directory.
async fn execute_astgrep_impl(
  spawner : &AstGrepSpawn,
  anchor : @devkit.WorkspaceAnchor?,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let query = match extract_astgrep_args(call.arguments) {
    Ok(query) => query
    Err(message) =>
      return @posoco.ToolOutcome::ToolReportedError(
        content=message,
        structured=None,
      )
  }
  let base = match (anchor, query.path) {
    (Some(anchor), Some(path)) => anchor.resolve(path)
    (Some(anchor), None) => anchor.root
    (None, Some(path)) => path
    (None, None) => "."
  }
  let positional = if base == "." { None } else { Some(base) }
  let argv = build_astgrep_args(
    query.pattern,
    query.lang,
    positional,
    query.glob,
  )
  let (exit_code, stdout, stderr) = spawner.spawn(argv)
  render_astgrep_result(exit_code, stdout, stderr, base, query.max_matches)
}
