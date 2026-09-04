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
/// in-process fallback). On wasm/wasm-gc the tool is not listed and execute
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
/// One parsed tool-call query: the ast-grep pattern plus optional filters.
priv struct AstGrepQuery {
  pattern : String
  lang : String?
  path : String?
  glob : String?
}

///|
/// Target seam: run one ast-grep argv (the binary itself is the backend's
/// probe winner), returning `(exit_code, stdout, stderr)`. Backends
/// implement only this; probe + argv + rendering stay in the shared impl.
priv trait AstGrepSpawn {
  async fn spawn(self : Self, argv : Array[String]) -> (Int, String, String) raise @posoco.RuntimeError
}

///|
/// Shared tool definition for the `astgrep` tool.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("astgrep"),
      description: "Structural code search with ast-grep: match code by its AST shape using a pattern with meta-variables (e.g. 'fn $NAME($$$ARGS) { $$$BODY }'), not by literal text or regex. Works on every language ast-grep supports (JavaScript, TypeScript, Python, Rust, Go, Java, ...). Optional arguments: 'lang' forces the tree-sitter language (otherwise inferred per file); 'path' is the directory or file to search (default: '.'); 'glob' filters searched files (e.g. '*.ts').",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "pattern": Json::object({
            "type": Json::string("string"),
            "description": Json::string(
              "ast-grep pattern with meta-variables like $NAME or $$$BODY (required)",
            ),
          }),
          "lang": Json::object({
            "type": Json::string("string"),
            "description": Json::string(
              "Tree-sitter language id (e.g. 'ts', 'py'); inferred per file when omitted",
            ),
          }),
          "path": Json::object({
            "type": Json::string("string"),
            "description": Json::string(
              "Directory or file to search (default: '.')",
            ),
          }),
          "glob": Json::object({
            "type": Json::string("string"),
            "description": Json::string(
              "File filter, e.g. '*.ts' or a glob list like '*.ts,*.js'",
            ),
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
    _ =>
      return Err(
        "astgrep: invalid arguments; pass a JSON object with a 'pattern' string holding an ast-grep pattern",
      )
  }
  let pattern = match obj.get("pattern") {
    Some(String(s)) =>
      if s == "" {
        return Err(
          "astgrep: 'pattern' must be a non-empty ast-grep pattern (e.g. 'foo($$$ARGS)')",
        )
      } else {
        s
      }
    Some(_) =>
      return Err(
        "astgrep: 'pattern' must be a string holding an ast-grep pattern with meta-variables like $NAME or $$$BODY",
      )
    None =>
      return Err(
        "astgrep: missing 'pattern'; pass an ast-grep pattern such as 'fn $NAME($$$ARGS) { $$$BODY }'",
      )
  }
  let lang = match obj.get("lang") {
    Some(String(s)) => Some(s)
    None | Some(Null) => None
    Some(_) =>
      return Err(
        "astgrep: optional 'lang' must be a string tree-sitter language id",
      )
  }
  let path = match obj.get("path") {
    Some(String(s)) => Some(s)
    None | Some(Null) => None
    Some(_) => return Err("astgrep: optional 'path' must be a string")
  }
  let glob = match obj.get("glob") {
    Some(String(s)) => Some(s)
    None | Some(Null) => None
    Some(_) => return Err("astgrep: optional 'glob' must be a string")
  }
  Ok(AstGrepQuery::{ pattern, lang, path, glob, })
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
  let args : Array[String] = ["run", "-p", pattern]
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
  "astgrep: no ast-grep binary found (tried: \{candidates.join(", ")}); install it with `brew install ast-grep` — both the 'ast-grep' and 'sg' binary names are accepted"
}

///|
/// Structured payload for observers/UIs on a passthrough result; never sent
/// to the model. Plain ast-grep text output is passed through uncounted, so
/// the summary stays honest (`matches: "raw"`) and only the zero-match case
/// reports `count`.
fn astgrep_structured_raw() -> Json {
  Json::object(
    Map::from_array([
      ("summary", Json::string("raw ast-grep output")),
      ("matches", Json::string("raw")),
    ]),
  )
}

///|
/// Structured payload for the zero-match case (grep parity).
fn astgrep_structured_zero() -> Json {
  Json::object(
    Map::from_array([
      ("summary", Json::string("no matches")),
      ("count", Json::number(0.0)),
    ]),
  )
}

///|
/// Turn one spawn result into the tool outcome. Exit 0 passes ast-grep's
/// text through unchanged; empty stdout means zero matches; any other exit
/// surfaces stderr as a model-visible error with the sanitized base.
fn render_astgrep_result(
  exit_code : Int,
  stdout : String,
  stderr : String,
  pattern : String,
  base : String,
) -> @posoco.ToolOutcome {
  if exit_code == 0 {
    if stdout == "" {
      @posoco.ToolOutcome::Success(
        content="No matches found for: \{pattern}",
        structured=Some(astgrep_structured_zero()),
      )
    } else {
      @posoco.ToolOutcome::Success(
        content=stdout,
        structured=Some(astgrep_structured_raw()),
      )
    }
  } else {
    let detail = if stderr != "" { stderr } else { stdout }
    @posoco.ToolOutcome::ToolReportedError(
      content="astgrep: ast-grep failed for '\{@devkit.sanitize_path(base)}' (exit \{exit_code}): \{detail}",
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
  render_astgrep_result(exit_code, stdout, stderr, query.pattern, base)
}
